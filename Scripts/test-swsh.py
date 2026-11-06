#!/usr/bin/env python3
"""Isolated process acceptance checks for swsh's batch runtime.

Usage: Scripts/test-swsh.py /absolute/path/to/swsh
Every shell gets its own test session; timeouts kill that test session.
"""
import json
import os
import fcntl
import struct
import pty
import shlex
from pathlib import Path
import signal
import select
import subprocess
import sys
import tempfile
import time
import unittest
import termios

from swsh_pty import PtyShell

SHELL = str(Path(sys.argv.pop(1)).resolve())

from swsh_language_tests import LanguageInteractionTests, LanguageLifecycleTests, CompletionContractTests, configure, eventually, children
configure(SHELL)


def collect(process, timeout=10):
    try:
        return process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise


def launch(source, **kwargs):
    return subprocess.Popen(
        [SHELL, "-c", source], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True, **kwargs,
    )


class BatchTests(unittest.TestCase):
    def test_shutdown_while_batch_source_pipe_is_idle(self):
        for shutdown_signal in (signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=shutdown_signal):
                process = subprocess.Popen(
                    [SHELL], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, start_new_session=True,
                )
                try:
                    # Leave the source pipe open without a complete program/EOF.
                    process.stdin.write(b"true\n")
                    process.stdin.flush()
                    time.sleep(0.15)
                    process.send_signal(shutdown_signal)
                    # communicate() would close stdin and hide the blocked read.
                    self.assertEqual(process.wait(timeout=3), 128 + shutdown_signal)
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()

    def run_source(self, source, status=0, **kwargs):
        process = launch(source, **kwargs)
        output, error = collect(process)
        self.assertEqual(process.returncode, status, (source, output, error))
        return output, error

    def test_batch_attached_to_tty_keeps_inherited_foreground_group(self):
        probe = (
            "import os; "
            "assert os.getpgrp() == os.getppid(); "
            "assert os.tcgetpgrp(0) == os.getpgrp(); "
            "print('INHERITED_FOREGROUND', flush=True)"
        )
        source = shlex.quote(sys.executable) + " -c " + shlex.quote(probe)
        pid, master = pty.fork()
        if pid == 0:
            os.execv(SHELL, [SHELL, "-c", source])
        reaped = False
        output = b""
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.05)[0]:
                    try:
                        output += os.read(master, 4096)
                    except OSError:
                        pass
                ended, status = os.waitpid(pid, os.WNOHANG)
                if ended:
                    reaped = True
                    self.assertEqual(os.waitstatus_to_exitcode(status), 0, output)
                    self.assertIn(b"INHERITED_FOREGROUND", output)
                    break
            self.assertTrue(reaped, output)
        finally:
            if not reaped:
                os.killpg(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            os.close(master)

    def test_scalars_and_assignment_state(self):
        output, _ = self.run_source(
            "name='two words'; /usr/bin/printf '<%s>\\n' $name \"$name\" $unset ''; "
            "name='*?'; /usr/bin/printf '<%s>\\n' $name"
        )
        self.assertEqual(output, b"<two words>\n<two words>\n<>\n<>\n<*?>\n")

    def test_environment_overlay_and_raw_bytes(self):
        environment = os.environb | {b"RAW": b"\xff*", b"OPAQUE\xff": b"preserved"}
        output, _ = self.run_source("/usr/bin/printf '%s' $RAW", env=environment)
        self.assertEqual(output, b"\xff*")
        output, _ = self.run_source(
            "x=parent; export x; x=child /bin/sh -c 'printf %s \"$x\"'; "
            "/usr/bin/printf ':%s' $x; unset x; /usr/bin/printf ':%s' $x"
        )
        self.assertEqual(output, b"child:parent:")
        output, _ = self.run_source("/usr/bin/env", env=environment)
        self.assertIn(b"OPAQUE\xff=preserved\n", output)

    def test_pipeline_streaming_and_status(self):
        output, _ = self.run_source("/usr/bin/yes | /usr/bin/head -n 1")
        self.assertEqual(output, b"y\n")
        output, _ = self.run_source("/usr/bin/head -c 1048576 /dev/zero | /usr/bin/wc -c")
        self.assertEqual(int(output), 1048576)
        output, error = self.run_source("/bin/sh -c '/usr/bin/head -c 1048576 /dev/zero >&2'")
        self.assertEqual(output, b"")
        self.assertEqual(error, bytes(1048576))
        output, _ = self.run_source("/usr/bin/printf x | swsh-missing-command | /usr/bin/wc -c")
        self.assertEqual(int(output), 0)
        self.run_source("/usr/bin/printf x | swsh-missing-command", status=127)
        self.run_source("/bin/sh -c 'kill -TERM $$'", status=143)

    def test_lookup_failures_apply_ordered_redirects(self):
        with tempfile.TemporaryDirectory() as directory:
            blocked = Path(directory, "blocked")
            blocked.write_text("never execute")
            blocked.chmod(0o600)
            for command, status in [("swsh-no-such-command", 127), ("./blocked", 126)]:
                output, error = self.run_source(command + " 2>errors", status=status, cwd=directory)
                self.assertEqual((output, error), (b"", b""))
                self.assertIn(b"command lookup failed", Path(directory, "errors").read_bytes())
                self.run_source(command + " 2>>errors", status=status, cwd=directory)
                self.assertEqual(Path(directory, "errors").read_bytes().count(b"command lookup failed"), 2)
                for redirect in ("2>/dev/null", "2>&-"):
                    self.assertEqual(self.run_source(command + " " + redirect, status=status, cwd=directory), (b"", b""))
                output, error = self.run_source(command + " 2>&1 >out", status=status, cwd=directory)
                self.assertIn(b"command lookup failed", output)
                self.assertEqual(error, b"")
                self.assertEqual(Path(directory, "out").read_bytes(), b"")
                output, error = self.run_source(command + " 2>&1 | /bin/cat", cwd=directory)
                self.assertIn(b"command lookup failed", output)
                self.assertEqual(error, b"")
                self.run_source(command + " >/missing-swsh-directory/out", status=1, cwd=directory)

    def test_missing_command_fifo_redirect_remains_supervised(self):
        with tempfile.TemporaryDirectory() as directory:
            os.mkfifo(Path(directory, "fifo"))
            output, error = self.run_source(
                "swsh-no-such-command >fifo | /bin/cat <fifo", cwd=directory
            )
            self.assertEqual(output, b"")
            self.assertIn(b"command lookup failed", error)

    def test_redirect_order(self):
        with tempfile.TemporaryDirectory() as directory:
            source = "/bin/sh -c 'printf out; printf err >&2'"
            output, error = self.run_source(source + " >one 2>&1", cwd=directory)
            self.assertEqual((output, error), (b"", b""))
            self.assertEqual(Path(directory, "one").read_bytes(), b"outerr")
            output, error = self.run_source(source + " 2>&1 >two", cwd=directory)
            self.assertEqual((output, error), (b"err", b""))
            self.assertEqual(Path(directory, "two").read_bytes(), b"out")

    def test_parent_builtin_redirects_preserve_state_and_descriptor_order(self):
        with tempfile.TemporaryDirectory() as directory:
            expected = os.fsencode(str(Path(directory).resolve())) + b"\n"
            output, error = self.run_source(
                "x=old; export x=new >empty; pwd 64>pwd 1>&64 64>&-; "
                "cd /swsh-missing-directory >one 2>&1; "
                "cd /swsh-missing-directory 2>&1 >two; "
                "export x=wrong >missing/file; /usr/bin/printf '%s:%s:' $? $x; "
                "x=assigned >assignment; /usr/bin/printf '%s:' $x; "
                "x=wrong >missing/file; /usr/bin/printf '%s:' $x; "
                "pwd 1>&-; /usr/bin/printf '%s' $?", cwd=directory
            )
            self.assertIn(b"swsh:", output)
            self.assertTrue(output.endswith(b"1:new:assigned:assigned:1"), output)
            self.assertIn(b"Bad file descriptor", error)
            self.assertEqual(Path(directory, "pwd").read_bytes(), expected)
            self.assertIn(b"swsh:", Path(directory, "one").read_bytes())
            for file in ("two", "empty", "assignment"):
                self.assertEqual(Path(directory, file).read_bytes(), b"")
            Path(directory, "sub").mkdir()
            output, error = self.run_source("cd sub >cd; pwd; exit 17 >exit", status=17, cwd=directory)
            self.assertEqual(output, os.fsencode(str(Path(directory, "sub").resolve())) + b"\n")
            self.assertEqual(error, b"")
            self.assertTrue(Path(directory, "sub", "exit").exists())

    def test_parent_builtin_fifo_and_shutdown(self):
        with tempfile.TemporaryDirectory() as directory:
            os.mkfifo(Path(directory, "fifo"))
            output, error = self.run_source(
                "/bin/cat fifo >result & pwd >fifo; /bin/sleep 0.05; /bin/cat result",
                cwd=directory
            )
            self.assertEqual(output, os.fsencode(str(Path(directory).resolve())) + b"\n")
            self.assertEqual(error, b"")
            process = launch("export changed=yes >fifo; /usr/bin/printf MUST_NOT_RUN", cwd=directory)
            time.sleep(0.1)
            process.send_signal(signal.SIGTERM)
            output, error = collect(process, timeout=6)
            self.assertEqual(process.returncode, 143, (output, error))
            self.assertNotIn(b"MUST_NOT_RUN", output)

    def test_parent_builtin_raw_path_and_closed_standard_slot(self):
        with tempfile.TemporaryDirectory() as directory:
            name = "out ' $ * é".encode()
            environment = os.environb | {b"DEST": name}
            output, error = self.run_source("pwd >$DEST", cwd=directory, env=environment)
            self.assertEqual((output, error), (b"", b""))
            with open(os.fsencode(directory) + b"/" + name, "rb") as file:
                self.assertEqual(file.read(), os.fsencode(str(Path(directory).resolve())) + b"\n")
            # APFS rejects invalid UTF-8 names; preserve that OS error instead
            # of decoding with replacement and silently creating another path.
            # Linux filesystems take any bytes, so there the exact name is created.
            invalid = sys.platform == "darwin"
            output, error = self.run_source("pwd >$DEST", status=1 if invalid else 0, cwd=directory,
                                           env=os.environb | {b"DEST": b"out\xff"})
            if invalid:
                self.assertIn(b"Illegal byte sequence", error)
            else:
                os.unlink(os.fsencode(directory) + b"/out\xff")
            self.assertEqual(len(list(Path(directory).iterdir())), 1)
            # The launch wrapper closes stdout before starting swsh. Receiving
            # SCM_RIGHTS must not accidentally reopen that standard slot.
            script = "import os; os.close(1); os.execv(os.environ['PROBE_SHELL'], ['swsh', '-c', \"pwd >out; /bin/sh -c 'test ! -e /dev/fd/1'\"])"
            process = subprocess.run([sys.executable, "-c", script], cwd=directory,
                                     env=os.environ | {"PROBE_SHELL": SHELL}, capture_output=True, timeout=6)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(process.stdout, b"")

    def test_fifo_launch_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            os.mkfifo(Path(directory, "fifo"))
            output, _ = self.run_source(
                "/bin/cat <fifo | /bin/sh -c 'echo ready >fifo; cat'", cwd=directory
            )
            self.assertEqual(output, b"ready\n")

    def test_fifo_without_peer_is_interruptible(self):
        with tempfile.TemporaryDirectory() as directory:
            os.mkfifo(Path(directory, "fifo"))
            process = launch("/bin/cat <fifo", cwd=directory)
            time.sleep(0.2)
            process.send_signal(signal.SIGTERM)
            output, error = collect(process, timeout=6)
            self.assertEqual(process.returncode, 143, (output, error))

    def test_shutdown_escalates_for_term_ignoring_child(self):
        process = launch("/bin/sh -c 'trap \"\" HUP TERM; echo ready; exec /bin/sleep 30'")
        try:
            self.assertTrue(select.select([process.stdout], [], [], 5)[0])
            self.assertEqual(process.stdout.readline(), b"ready\n")
            started = time.monotonic()
            process.send_signal(signal.SIGTERM)
            output, error = collect(process, timeout=6)
            elapsed = time.monotonic() - started
            self.assertEqual(process.returncode, 143, (output, error))
            self.assertGreaterEqual(elapsed, 1.9)
            self.assertLess(elapsed, 5)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()

    def test_redirect_failure_keeps_neighbor(self):
        output, _ = self.run_source("/bin/cat </swsh-missing-file | /usr/bin/printf neighbor")
        self.assertEqual(output, b"neighbor")
        self.run_source("/bin/cat </swsh-missing-file", status=1)

    def test_batch_completion_retires_running_and_stopped_jobs(self):
        for stopped in (False, True):
            with self.subTest(stopped=stopped), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                child = root / "child"
                child.write_text(
                    "#!/bin/sh\ntrap '' HUP TERM\necho $$ >pid\n"
                    + ("kill -STOP $$\n" if stopped else "")
                    + "exec /bin/sleep 30\n"
                )
                child.chmod(0o700)
                started = time.monotonic()
                self.run_source(
                    "./child & /bin/sh -c 'while [ ! -s pid ]; do sleep 0.01; done'; false",
                    status=1, cwd=directory,
                )
                self.assertGreaterEqual(time.monotonic() - started, 1.9)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int((root / "pid").read_text()), 0)

    def test_private_launcher_replacement_failure_keeps_neighbor(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory, "bad-format")
            script.write_text("echo must-not-execute\n")
            script.chmod(0o700)
            output, _ = self.run_source(
                "./bad-format 2>error | /usr/bin/printf neighbor", cwd=directory
            )
            self.assertEqual(output, b"neighbor")
            self.assertIn(b"execve", Path(directory, "error").read_bytes())
            output, _ = self.run_source("./bad-format >output", status=126, cwd=directory)
            self.assertEqual(output, b"")
            self.assertEqual(Path(directory, "output").read_bytes(), b"")

    def test_real_interpreters_and_no_format_fallback(self):
        for interpreter in ["/bin/bash", "/bin/zsh"]:
            output, _ = self.run_source(interpreter + " -c 'printf \"%s\" \"$1\"' probe 'two words'")
            self.assertEqual(output, b"two words")
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory, "program.sh")
            script.write_text("echo must-not-run\n")
            script.chmod(0o700)
            output, _ = self.run_source("./program.sh", status=126, cwd=directory)
            self.assertEqual(output, b"")
            script.write_text("#!/bin/sh\nprintf shebang\n")
            output, _ = self.run_source("./program.sh", cwd=directory)
            self.assertEqual(output, b"shebang")

    def test_cwd_and_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            output, _ = self.run_source("cd /; pwd; /bin/pwd; exit 17; /usr/bin/printf unreachable", status=17, cwd=directory)
            self.assertEqual(output, b"/\n/\n")
        output, _ = self.run_source("false && /usr/bin/printf bad || /usr/bin/printf good; true || /usr/bin/printf bad")
        self.assertEqual(output, b"good")

    def test_builtin_workers_isolate_state_and_select_last_status(self):
        with tempfile.TemporaryDirectory() as directory:
            output, _ = self.run_source(
                "pwd | /bin/cat; cd / | /bin/cat; pwd; "
                "x=parent; export x=child | /bin/cat; unset x | /bin/cat; "
                "/usr/bin/printf '%s' $x; exit 19 | /bin/cat; /usr/bin/printf alive",
                cwd=directory,
            )
            physical = os.path.realpath(directory).encode()
            self.assertEqual(output, physical + b"\n" + physical + b"\nparentalive")
        self.run_source("false | true")
        self.run_source("true | false", status=1)
        self.run_source("/usr/bin/printf ignored | exit 19", status=19)

    def test_builtin_worker_large_payload_and_fifo_redirect(self):
        with tempfile.TemporaryDirectory() as directory:
            program = Path(directory, "large.swsh")
            program.write_text("large='" + "x" * (256 * 1024) + "'; : $large | /bin/cat")
            process = subprocess.Popen([SHELL, str(program)], stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True)
            output, error = collect(process)
            self.assertEqual((process.returncode, output, error), (0, b"", b""))
            os.mkfifo(Path(directory, "fifo"))
            output, _ = self.run_source("pwd >fifo | /bin/sh -c 'cat fifo'", cwd=directory)
            self.assertEqual(output, os.path.realpath(directory).encode() + b"\n")

    def test_prelaunch_rejection(self):
        self.run_source("x=1 cd /", status=2)
        self.run_source("fg | /usr/bin/printf unreachable", status=2)
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "a").touch()
            Path(directory, "b").touch()
            output, _ = self.run_source("/usr/bin/printf unreachable >*", status=2, cwd=directory)
            self.assertEqual(output, b"")


class ExecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory()
        cls.probe = str(Path(cls.workspace.name, "exec-probe"))
        fixture = Path(__file__).resolve().parent.parent / "Tests/SwshTests/Fixtures/exec-probe.c"
        subprocess.run((["xcrun", "clang"] if sys.platform == "darwin" else ["clang"]) + ["-Wall", "-Wextra", "-Werror", str(fixture), "-o", cls.probe], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def test_main_pid_descriptors_signals_and_environment(self):
        read_fd, inherited = os.pipe()
        try:
            process = launch(f"exec '{self.probe}' 'argument with spaces'", pass_fds=(inherited,),
                             cwd=self.workspace.name, env=os.environb | {b"RAW": b"\xff*"})
            output, error = collect(process)
            self.assertEqual(process.returncode, 23, error)
            report = dict(line.split(b"=", 1) for line in output.splitlines())
            self.assertEqual(int(report[b"pid"]), process.pid)
            self.assertEqual(int(report[b"group"]), process.pid)
            self.assertEqual(report[b"defaults"], b"1")
            self.assertEqual(report[b"unblocked"], b"1")
            self.assertEqual(report[b"fds"], f"{inherited},".encode())
            self.assertEqual(bytes.fromhex(report[b"cwd"].decode()), os.path.realpath(self.workspace.name).encode())
            self.assertEqual(bytes.fromhex(report[b"argument"].decode()), b"argument with spaces")
            self.assertEqual(report[b"raw"], b"ff2a")
        finally:
            os.close(read_fd)
            os.close(inherited)

    def test_failed_exec_continues_without_changing_logical_state(self):
        invalid = Path(self.workspace.name, "bad-format")
        invalid.write_text("this is not an executable image\n")
        invalid.chmod(0o700)
        process = launch(f"value=retained; exec '{invalid}'; /usr/bin/printf '<%s>:%s' $? $value")
        output, error = collect(process)
        self.assertEqual(process.returncode, 0, error)
        self.assertEqual(output, b"<126>:retained")
        process = launch("exec swsh-missing-executable; /usr/bin/printf '%s' $?")
        output, error = collect(process)
        self.assertEqual((process.returncode, output), (0, b"127"), error)
        process = launch(f"exec '{invalid}' | /usr/bin/printf neighbor")
        output, error = collect(process)
        self.assertEqual((process.returncode, output), (0, b"neighbor"), error)
        process = launch(f"/usr/bin/true | exec '{invalid}'")
        output, error = collect(process)
        self.assertEqual(process.returncode, 126, error)
        process = launch("PATH=/bin; export value=worker-environment; exec sh -c 'printf %s \"$value\"' | /bin/cat")
        output, error = collect(process)
        self.assertEqual((process.returncode, output), (0, b"worker-environment"), error)

    def test_worker_exec_uses_unexported_path_and_preserves_raw_bytes(self):
        process = launch(f"unset PATH; PATH='{self.workspace.name}'; exec exec-probe $RAW | /bin/cat",
                         env=os.environb | {b"RAW": b"\xff*"})
        output, error = collect(process)
        self.assertEqual(process.returncode, 0, error)
        report = dict(line.split(b"=", 1) for line in output.splitlines())
        self.assertEqual(report[b"argument"], b"ff2a")
        self.assertEqual(report[b"raw"], b"ff2a")
        self.assertEqual(report[b"fds"], b"")
        self.assertNotEqual(int(report[b"pid"]), process.pid)
        self.assertEqual(int(report[b"group"]), process.pid)

    def test_exec_decorations_rejected_before_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            for source in ["exec /usr/bin/true >output", "exec /usr/bin/true >output | /bin/cat", "x=1 exec /usr/bin/true"]:
                process = launch(source, cwd=directory)
                _, error = collect(process)
                self.assertEqual(process.returncode, 2, error)
                self.assertFalse(Path(directory, "output").exists())

    def test_interactive_main_replacement_and_failed_replacement_recovery(self):
        invalid = Path(self.workspace.name, "interactive-bad-format")
        invalid.write_text("invalid executable\n")
        invalid.chmod(0o700)
        with PtyShell(SHELL) as shell:
            before = termios.tcgetattr(shell.fd)
            dispositions = subprocess.check_output([self.probe, "inspect", str(shell.pid)])
            output = shell.command(f"exec '{invalid}'")
            self.assertEqual(subprocess.check_output([self.probe, "inspect", str(shell.pid)]), dispositions)
            self.assertIn(b"133;D;126", output)
            self.assertEqual(termios.tcgetattr(shell.fd), before)
            shell.send(b"\x03")
            shell.prompt()  # SIGINT still belongs to the editor after failed SETEXEC.
            shell.send(b"\x1a")
            output = shell.command("/usr/bin/printf still-alive")
            self.assertIn(b"still-alive", output)
            shell.send(f"exec '{self.probe}'\n")
            self.assertEqual(shell.wait(), 23)
            self.assertIn(f"pid={shell.pid}\r\n".encode(), shell.buffer)
            self.assertIn(b"defaults=1\r\n", shell.buffer)
            self.assertIn(b"fds=\r\n", shell.buffer)
            self.assertTrue(termios.tcgetattr(shell.fd)[3] & termios.ICANON)

    def test_failed_replacement_preserves_blocked_signal_mask(self):
        invalid = Path(self.workspace.name, "mask-bad-format")
        invalid.write_text("invalid executable\n")
        invalid.chmod(0o700)
        with PtyShell(SHELL, blocked_signals=[signal.SIGUSR1]) as shell:
            output = shell.command(f"exec '{invalid}'")
            self.assertIn(b"133;D;126", output)
            os.kill(shell.pid, signal.SIGUSR1)
            # SIGUSR1 has default termination disposition. This command can run
            # only if failed SETEXEC preserved the shell thread's blocked mask.
            self.assertIn(b"mask-preserved", shell.command("/usr/bin/printf mask-preserved"))

    def test_failed_replacement_keeps_a_pending_blocked_signal_pending(self):
        invalid = Path(self.workspace.name, "pending-bad-format")
        invalid.write_text("invalid executable\n")
        invalid.chmod(0o700)
        with PtyShell(SHELL, blocked_signals=[signal.SIGUSR1]) as shell:
            # Pending before the attempt: clearing the mask for the new image
            # must not deliver it to the shell with its default action.
            os.kill(shell.pid, signal.SIGUSR1)
            output = shell.command(f"exec '{invalid}'")
            self.assertIn(b"133;D;126", output)
            self.assertIn(b"still-here", shell.command("/usr/bin/printf still-here"))

    def test_worker_replacement_retains_group_leader_pid_and_parent(self):
        with PtyShell(SHELL) as shell:
            shell.send("exec /bin/sh -c 'printf \"WORKER_PID=%s\\n\" \"$$\"; /bin/sleep 30' | /bin/cat\n")
            group = shell.foreground_job()
            shell.expect(f"WORKER_PID={group}\r\n".encode())
            self.assertNotEqual(group, shell.pid)
            shell.send(b"\x03")
            shell.prompt()
            self.assertEqual(os.tcgetpgrp(shell.fd), shell.pid)
            self.assertIn(b"parent-alive", shell.command("/usr/bin/printf parent-alive"))

    def test_exec_does_not_abandon_live_jobs(self):
        with PtyShell(SHELL) as shell:
            shell.command("/bin/sleep 30 &")
            output = shell.command("exec /usr/bin/true")
            self.assertIn(b"133;D;2", output)
            self.assertIn(b"running", shell.command("jobs"))


class InteractiveTests(unittest.TestCase):
    def test_parent_builtin_redirect_setup_interrupt_and_jobs_output(self):
        with PtyShell(SHELL, startup='/usr/bin/printf loaded >>"$HOME/startup-count"\n') as shell:
            fifo = Path(shell.home.name, "fifo")
            os.mkfifo(fifo)
            shell.send(f"export changed=yes >'{fifo}'\n")
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                children = subprocess.run(["/usr/bin/pgrep", "-P", str(shell.pid)], capture_output=True).stdout.split()
                if children:
                    break
                time.sleep(0.01)
            self.assertTrue(children)
            self.assertEqual(os.tcgetpgrp(shell.fd), shell.pid)
            shell.send(b"\x1a")  # Parent builtin setup shares the shell's stop policy.
            time.sleep(0.03)
            shell.send(b"\x03")
            self.assertIn(b"133;D;130", shell.prompt())
            output = shell.command("/usr/bin/printf '<%s>' $changed")
            self.assertIn(b"<>", output)
            shell.command("/bin/sleep 30 &")
            listing = Path(shell.home.name, "jobs")
            output = shell.command(f"jobs >'{listing}'")
            self.assertIn(b"running", listing.read_bytes())
            self.assertNotIn(b"\x1b", listing.read_bytes())
            self.assertEqual(Path(shell.home.name, "startup-count").read_bytes(), b"loaded")
            self.assertNotIn(b"running", output)
            shell.send("exit\n")
            self.assertEqual(shell.wait(), 0)


    def test_stop_background_foreground_and_interrupt(self):
        with PtyShell(SHELL) as shell:
            shell.send("/bin/sleep 30; /usr/bin/printf SHOULD_NOT_REPLAY\n")
            group = shell.foreground_job()
            shell.send(b"\x1a")
            output = shell.prompt()
            self.assertIn(b"stopped", output)
            self.assertEqual(os.tcgetpgrp(shell.fd), shell.pid)
            self.assertIn(b"stopped", shell.command("jobs"))
            shell.command("bg")
            self.assertIn(b"running", shell.command("jobs"))
            shell.send("fg\n")
            self.assertEqual(shell.foreground_job(), group)
            shell.send(b"\x03")
            output = shell.prompt()
            self.assertIn(b"133;D;130", output)
            self.assertNotIn(b"SHOULD_NOT_REPLAY", output)
            self.assertEqual(os.tcgetpgrp(shell.fd), shell.pid)

    def test_interactive_fifo_and_background(self):
        with PtyShell(SHELL) as shell:
            fifo = Path(shell.home.name, "fifo")
            os.mkfifo(fifo)
            output = shell.command(f"/bin/cat <'{fifo}' | /bin/sh -c 'echo ready >\"{fifo}\"; cat'")
            self.assertIn(b"ready\r\n", output)
            output = shell.command("/bin/sleep 30 &")
            self.assertIn(b"scheduled", output)
            self.assertEqual(os.tcgetpgrp(shell.fd), shell.pid)
            self.assertIn(b"running", shell.command("jobs"))
            shell.send("exit 23\n")
            self.assertEqual(shell.wait(), 23)

    def test_wrapped_editing_completion_history_and_resize(self):
        with PtyShell(SHELL) as shell:
            fcntl.ioctl(shell.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 8, 20, 0, 0))
            shell.send("x" * 55)
            time.sleep(0.05)
            shell.drain_available()
            fcntl.ioctl(shell.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 6, 12, 0, 0))
            time.sleep(1.1)  # The editor also observes resize while idle.
            shell.drain_available()
            shell.send(b"\x15")
            shell.send("/usr/bin/printf WRAPPED_EDIT_OX")
            shell.send(b"\x7fK\n")
            self.assertIn(b"WRAPPED_EDIT_OK", shell.prompt())
            shell.send(b"\x1b[A\n")
            self.assertIn(b"WRAPPED_EDIT_OK", shell.prompt())
            shell.send("/bin/ec")
            shell.send(b"\t")
            shell.send(" WRAPPED_COMPLETION_OK\n")
            self.assertIn(b"WRAPPED_COMPLETION_OK", shell.prompt())

    def test_editor_interrupt_continuation_and_history(self):
        with PtyShell(SHELL, startup="value=from_rc\n") as shell:
            output = shell.command("/usr/bin/printf '<%s>\\n' $value")
            self.assertIn(b"<from_rc>\r\n", output)
            shell.send("/usr/bin/printf BAD")
            shell.send(b"\x03")
            shell.prompt()
            shell.send("/usr/bin/printf 'continued")
            shell.send("\n")
            shell.expect(b"...> ")
            shell.send("value'\n")
            output = shell.prompt()
            self.assertIn(b"continued\r\nvalue", output)
            shell.command("/usr/bin/printf HISTORY_MARKER")
            shell.send(b"\x1b[A\n")
            output = shell.prompt()
            self.assertIn(b"HISTORY_MARKER", output)
            history = Path(shell.home.name, ".swsh_history")
            self.assertTrue(history.exists())
            self.assertEqual(history.stat().st_mode & 0o777, 0o600)
            shell.send(b"\x04")
            self.assertEqual(shell.wait(), 0)

    def test_raw_job_modes_survive_fg_and_bg(self):
        helper = Path(__file__).resolve().parent.parent / "Tests/SwshTests/Fixtures/raw-job.py"
        for action in ["fg", "bg"]:
            with self.subTest(action=action), PtyShell(SHELL) as shell:
                editor = termios.tcgetattr(shell.fd)
                shell.send(f"/usr/bin/python3 '{helper}' {action}\n")
                shell.expect(b"RAW_READY\n")
                shell.prompt()
                self.assertEqual(termios.tcgetattr(shell.fd), editor)
                if action == "bg":
                    background = shell.command("bg")
                    if b"BG_EDITOR_MODES" not in background:
                        shell.expect(b"BG_EDITOR_MODES")
                    # The helper stops again after observing editor modes. Drain
                    # its transition before fg; the sleep is an owned foreground job.
                    shell.command("/bin/sleep 0.05")
                    self.assertEqual(termios.tcgetattr(shell.fd), editor)
                output = shell.command("fg")
                self.assertIn(b"FG_MODES_RESTORED", output)
                self.assertIn(b"133;D;0", output)
                self.assertEqual(termios.tcgetattr(shell.fd), editor)

    def test_mixed_pipeline_waits_for_all_live_stages(self):
        with PtyShell(SHELL) as shell:
            started = time.monotonic()
            output = shell.command("/bin/sh -c 'kill -STOP $$; exit 11' | /bin/sleep 0.2")
            self.assertGreaterEqual(time.monotonic() - started, 0.18)
            self.assertIn(b"stopped", output)
            output = shell.command("fg")
            self.assertIn(b"133;D;0", output)
            # The last stage's retained result wins even after the leader exits 11.
            self.assertEqual(os.tcgetpgrp(shell.fd), shell.pid)

    def test_repeated_stop_resume_does_not_use_stale_flags(self):
        with PtyShell(SHELL) as shell:
            output = shell.command("/bin/sh -c 'kill -STOP $$; kill -STOP $$; printf finished'")
            self.assertIn(b"stopped", output)
            output = shell.command("fg")
            self.assertIn(b"stopped", output)
            output = shell.command("fg")
            self.assertIn(b"finished", output)
            self.assertIn(b"133;D;0", output)

    def test_background_nested_shell_waits_for_foreground(self):
        with PtyShell(SHELL) as shell:
            shell.command(f"'{SHELL}' -i &")
            shell.command("/bin/sleep 0.05")
            self.assertIn(b"stopped", shell.command("jobs"))
            self.assertEqual(os.tcgetpgrp(shell.fd), shell.pid)
            shell.send("fg\n")
            shell.prompt()  # The nested shell's first prompt.
            self.assertNotEqual(os.tcgetpgrp(shell.fd), shell.pid)
            shell.send("exit\n")
            shell.prompt()  # The outer shell reclaims the terminal.
            self.assertEqual(os.tcgetpgrp(shell.fd), shell.pid)

    def test_shutdown_triggers_retire_running_and_stopped_jobs(self):
        for stopped in (False, True):
            for trigger in ("exit", "eof", "hangup"):
                with self.subTest(stopped=stopped, trigger=trigger), PtyShell(SHELL) as shell:
                    pid_file = Path(shell.home.name, "child-pid")
                    program = "trap '' HUP TERM; echo $$ > " + shlex.quote(str(pid_file)) + "; exec /bin/sleep 30"
                    shell.command("/bin/sh -c " + shlex.quote(program) + " &")
                    deadline = time.monotonic() + 3
                    while not pid_file.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    child = int(pid_file.read_text())
                    if stopped:
                        os.kill(child, signal.SIGSTOP)
                        deadline = time.monotonic() + 3
                        while b"stopped" not in shell.command("jobs"):
                            self.assertLess(time.monotonic(), deadline)
                    shell.command("false")
                    started = time.monotonic()
                    if trigger == "hangup":
                        status = shell.hangup()
                    else:
                        shell.send("exit 17\n" if trigger == "exit" else b"\x04")
                        status = shell.wait()
                    self.assertEqual(status, {"exit": 17, "eof": 1, "hangup": 129}[trigger])
                    self.assertGreaterEqual(time.monotonic() - started, 1.9)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(child, 0)

    def test_hangup_and_foreground_eof(self):
        with PtyShell(SHELL) as shell:
            shell.send("/bin/cat\n")
            shell.foreground_job()
            shell.send(b"\x04")
            shell.prompt()
            self.assertEqual(os.tcgetpgrp(shell.fd), shell.pid)
            self.assertEqual(shell.hangup(), 129)

    def test_completion_and_bracketed_paste(self):
        with PtyShell(SHELL) as shell:
            shell.send("/usr/bin/printf '\\n'; /usr/bin/prin")
            # Quoting deliberately disables this initial completion contract.
            shell.send(b"\x15")
            shell.send("/bin/ec")
            shell.send(b"\t")
            shell.send("COMPLETED\n")
            output = shell.prompt()
            self.assertIn(b"COMPLETED", output)
            shell.send(b"\x1b[200~/usr/bin/printf first\n/usr/bin/printf second\x1b[201~")
            # Embedded newlines are source, not Enter presses; only this Enter submits.
            shell.send(b"\n")
            output = shell.prompt()
            self.assertIn(b"firstsecond", output)

    def test_builtin_workers_do_not_repeat_startup_or_deadlock_on_large_payload(self):
        startup = "/usr/bin/printf loaded >>\"$HOME/startup-count\"\nlarge='" + "x" * (256 * 1024) + "'\n"
        with PtyShell(SHELL, startup=startup) as shell:
            output = shell.command(": $large | /bin/cat")
            self.assertIn(b"133;D;0", output)
            fifo = Path(shell.home.name, "fifo")
            os.mkfifo(fifo)
            output = shell.command(f"pwd >'{fifo}' | /bin/cat '{fifo}'")
            self.assertIn(b"133;D;0", output)
            self.assertEqual(Path(shell.home.name, "startup-count").read_bytes(), b"loaded")

    def test_editor_and_command_terminal_modes(self):
        with PtyShell(SHELL) as shell:
            editor = termios.tcgetattr(shell.fd)
            self.assertFalse(editor[3] & termios.ICANON)
            self.assertFalse(editor[3] & termios.ECHO)
            shell.send("/bin/sleep 30\n")
            shell.foreground_job()
            command = termios.tcgetattr(shell.fd)
            self.assertTrue(command[3] & termios.ICANON)
            self.assertTrue(command[3] & termios.ECHO)
            shell.send(b"\x1a")
            shell.prompt()
            restored = termios.tcgetattr(shell.fd)
            self.assertEqual(restored, editor)


class AgentProtocolTests(unittest.TestCase):
    """spec.shell.md §11: the headless interface describes requests and runs none without a context."""

    def exchange(self, frames, **kwargs):
        process = subprocess.Popen([SHELL, "--agent"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True, **kwargs)
        output, error = process.communicate(b"".join(frames), timeout=20)
        self.assertEqual((process.returncode, error), (0, b""))
        self.assertTrue(all(32 <= byte <= 126 or byte == 10 for byte in output), output[:200])
        return [json.loads(line) for line in output.splitlines()]

    def request(self, **fields):
        base = {"protocol": "swsh.run/1", "requestId": "req-1", "operation": "run",
                "pipeline": [{"argv": ["git", "status"]}]}
        base.update(fields)
        return json.dumps({key: value for key, value in base.items() if value is not None}).encode() + b"\n"

    def test_requests_never_reach_the_host(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = os.path.join(directory, "marker")
            target = os.path.join(directory, "target")
            Path(target).write_text("keep")
            for name in ("git", "sh", "touch"):
                tool = Path(directory, name)
                tool.write_text(f"#!/bin/sh\n/usr/bin/touch {shlex.quote(marker)}\n")
                tool.chmod(0o755)
            Path(directory, ".swshrc").write_text(f"/usr/bin/touch {shlex.quote(marker)}\n")
            hostile = f"$(/usr/bin/touch {marker}) `/usr/bin/touch {marker}` > {target}; /usr/bin/touch {marker}"
            environment = {"PATH": directory + ":", "HOME": directory, "ENV": os.path.join(directory, ".swshrc"),
                           "SHELL": os.path.join(directory, "sh"), "SSH_AUTH_SOCK": os.path.join(directory, "agent")}
            results = self.exchange([
                self.request(pipeline=[{"argv": ["git", hostile, "--", marker]},
                                       {"argv": ["sh", "-c", f"/usr/bin/touch {marker}"]}]),
                self.request(requestId="req-2", pipeline=None, source=hostile),
                self.request(requestId="req-3", operation="preview", pipeline=[{"argv": ["touch", hostile]}]),
                self.request(requestId="req-4", operation="preview", pipeline=None, source=hostile),
                self.request(requestId="req-5", cwd=directory),
                self.request(requestId="req-6", approved=True, effectivePolicy="unrestricted", backendVerified=True),
                self.request(requestId="req-7", operation="create"),
                b'{"protocol": "swiftty.exec/1", "requestId": "req-8", "sessionId": "s", "operation": "create", "image": "i", "snapshots": []}\n',
            ], cwd=directory, env=environment)
            self.assertEqual([(r["requestId"], r["outcome"]) for r in results], [
                ("req-1", "no_context"), ("req-2", "no_context"), ("req-3", "previewed"),
                ("req-4", "unsupported_operation"), ("req-5", "invalid_request"), ("req-6", "invalid_request"),
                ("req-7", "unsupported_operation"), ("req-8", "unsupported_protocol")])
            for result in results:
                self.assertEqual(result["effects"], "none")
                # swsh authors no statement about policy.
                self.assertFalse({"approved", "confined", "backend", "scope"} & set(result))
            # A preview shows exactly the bytes that would be passed, unexpanded.
            self.assertEqual(results[2]["stages"], [{"argv": [{"text": "touch"}, {"text": hostile}], "unresolved": []}])
            self.assertEqual([r["stages"] for r in results[:2] + results[3:]], [None] * 7)
            self.assertEqual(len(results[0]["requestIdentity"]), 64)
            self.assertFalse(os.path.exists(marker))
            self.assertEqual(Path(target).read_text(), "keep")
            self.assertEqual(sorted(os.listdir(directory)), [".swshrc", "git", "sh", "target", "touch"])

    def test_frames_are_bounded_and_output_is_inert(self):
        results = self.exchange([
            b"\n  \n",
            b"x" * (2 * 1024 * 1024) + b"\n",
            self.request(),
            self.request(requestId="req-7", **{"\x1b]0;approved\x07": 1}),
            b"[" * 100000 + b"\n",
            self.request(pipeline=[{"argv": ["a" * 70000]}]),
            self.request(pipeline=[{"argv": ["t"]}] * 9),
            self.request(pipeline=None, source="x" * 300000),
            b"\xff\xfe\n",
            b'{"protocol": "swsh.run/1", "requestId": "partial"',
        ])
        self.assertEqual([(r["requestId"], r["outcome"]) for r in results], [
            (None, "invalid_request"), ("req-1", "no_context"), ("req-7", "invalid_request"),
            (None, "invalid_request"), ("req-1", "invalid_request"), ("req-1", "invalid_request"),
            ("req-1", "invalid_request"), (None, "invalid_request")])
        self.assertIn("1048576", results[0]["reason"])
        self.assertIn("\x1b]0;approved\x07", results[2]["reason"])

    def test_agent_mode_takes_no_other_arguments(self):
        for arguments in (["--agent", "-c", "/bin/echo x"], ["--agent", "--agent"]):
            process = subprocess.run([SHELL, *arguments], stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
            self.assertEqual((process.returncode, process.stdout), (2, b""))


class LanguageGrowthTests(unittest.TestCase):
    def run_source(self, source, expected, status=0):
        process = launch(source)
        output, error = collect(process)
        self.assertEqual(process.returncode, status, error)
        self.assertEqual(output, expected, error)

    def test_history_survives_a_new_shell_process(self):
        with PtyShell(SHELL) as first:
            first.command("/bin/echo persisted-history-token")
            history = Path(first.home.name, ".swsh_history").read_bytes()
        with PtyShell(SHELL) as second:
            Path(second.home.name, ".swsh_history").write_bytes(history)
            # Restart within the same HOME so initialization reloads the store.
            second.send("exec '" + SHELL + "' -i\n")
            second.prompt()
            second.send(b"\x1b[A\x1b[A\n")
            self.assertIn(b"persisted-history-token", second.prompt())

    def test_arithmetic_values_and_diagnostics(self):
        self.run_source("n=5; /usr/bin/printf '<%s>' $((n * n)) $(($n + 1)) \"q$((n - 1))q\" $((1 << 4)) $((0 ? 1 / 0 : 9)) $((0x1f))",
                        b"<25><6><q4q><16><9><31>")
        self.run_source("/bin/echo $((/bin/echo subshell))", b"subshell\n")
        for source in ("/bin/echo $((1 / 0))", "/bin/echo $((9223372036854775807 + 1))", "x=abc; /bin/echo $((x + 1))"):
            with self.subTest(source=source):
                self.run_source(source + "; /bin/echo unreachable", b"", 2)

    def test_lists_expand_as_arguments_and_reject_scalar_use(self):
        self.run_source("""a=(one "two words" '*'); a+=(four); a[1]=TWO; a[4]=five
/usr/bin/printf '<%s>' ${a[@]} "${a[@]}" ${#a[@]} ${a[$((${#a[@]} - 1))]}
e=(); /usr/bin/printf '[%s]' x ${e[@]} ${#e[@]}""",
                        b"<one><TWO><*><four><five><one><TWO><*><four><five><5><five>[x][0]")
        self.run_source("(a=(child)); a=(1 2); f() { a+=(3); }; f; /usr/bin/printf '%s' ${#a[@]}; unset a; /usr/bin/printf ':%s' ${#a[@]}", b"3:0")
        for source in ("a=(1); /bin/echo $a", "a=(1); /bin/echo ${a[1]}", "a=(1); a[2]=x", "a=(1); /bin/echo x${a[@]}",
                       "export a; a=(1)", "a=(1) /bin/echo"):
            with self.subTest(source=source):
                self.run_source(source + "; /bin/echo unreachable", b"", 2)
        self.run_source("a=(1); export a; /usr/bin/printf '%s' $?", b"2")

    def test_heredocs_reach_externals_builtins_functions_and_pipelines(self):
        self.run_source("""n=5
/bin/cat <<EOF; /bin/cat <<'RAW'
$n $((n + 1)) $(/bin/echo sub) \\$n
EOF
$n \\$n
RAW
/bin/cat <<-TABS | /usr/bin/tr a-z A-Z
\tindented
\tTABS
f() { /bin/cat; }; f <<EOF
function $n
EOF
(/bin/cat) <<EOF
subshell
EOF
/bin/cat 3<<EOF <&3
descriptor
EOF
""", b"5 6 sub $n\n$n \\$n\nINDENTED\nfunction 5\nsubshell\ndescriptor\n")
        # Larger than a pipe buffer: delivery must not depend on a reader draining it.
        body = "x" * 200000
        # A script file: Linux limits one argument to 128 KiB.
        with tempfile.NamedTemporaryFile("w", suffix=".swsh") as script:
            script.write(f"/usr/bin/wc -c <<EOF\n{body}\nEOF\n")
            script.flush()
            result = subprocess.run([SHELL, script.name], capture_output=True, timeout=10)
        self.assertEqual((result.returncode, result.stdout.split(), result.stderr), (0, [b"200001"], b""))
        self.run_source("if true; then /bin/cat <<EOF; fi\nx\nEOF\n", b"", 2)

    def test_control_flow_runs_in_the_current_shell(self):
        self.run_source("""i=0; out=()
while /bin/test $i != 5; do
  i=$((i + 1))
  if /bin/test $i = 2; then continue; elif /bin/test $i = 4; then break; else out+=($i); fi
done
until false; do out+=(until); break; done
for x in ${out[@]} 'two words'; do /usr/bin/printf '<%s>' $x; done
/usr/bin/printf ':%s:%s' $i $x
if false; then /bin/echo no; fi; /usr/bin/printf ':%s' $?
! false; /usr/bin/printf ':%s' $?; ! true; /usr/bin/printf ':%s' $?
for x in; do /bin/echo never; done; /usr/bin/printf ':%s' $?""",
                        b"<1><3><until><two words>:4:two words:0:0:1:0")
        self.run_source("x=parent; for x in a b; do /bin/echo $x; done | /usr/bin/tr a-z A-Z; /usr/bin/printf '%s' $x", b"A\nB\nparent")
        self.run_source("while true; do /bin/echo once; exit 3; done", b"once\n", 3)
        self.run_source("f() { for x in 1 2; do return 4; done; }; f; /usr/bin/printf '%s:%s' $? $x", b"4:1")
        for source in ("break", "continue", "f() { break; }; while true; do f; done"):
            with self.subTest(source=source):
                self.run_source(source + "; /bin/echo unreachable", b"", 2)

    def test_errexit_nounset_and_pipefail(self):
        self.run_source("set -e; false || /usr/bin/printf a; if false; then :; fi; ! true; while false; do :; done; false && true; /usr/bin/printf b; false; /usr/bin/printf c",
                        b"ab", 1)
        self.run_source("set -e; f() { false; /usr/bin/printf in; }; if f; then /usr/bin/printf :then; fi; f; /usr/bin/printf unreachable", b"in:then", 1)
        self.run_source("set -e; (exit 6); /usr/bin/printf unreachable", b"", 6)
        self.run_source("set -e; /usr/bin/false | /usr/bin/true; /usr/bin/printf a; set -o pipefail; /usr/bin/true | /bin/sh -c 'exit 5' | /usr/bin/true; /usr/bin/printf b", b"a", 5)
        self.run_source("set -e; set +e; false; /usr/bin/printf '%s' $?", b"1")
        self.run_source("set -u; x=; /usr/bin/printf '<%s>' $x; /usr/bin/printf '%s' $missing; /usr/bin/printf unreachable", b"<>", 2)
        self.run_source("set -eu -o pipefail; set", b"set -o errexit\nset -o nounset\nset -o pipefail\n")
        self.run_source("set -x; /usr/bin/printf '%s' $?; set -e -o nope; /usr/bin/printf ':%s' $?; false; /usr/bin/printf :kept", b"2:2:kept")
        # Workers inherit the policies with the rest of the snapshot.
        self.run_source("set -e; (false; /usr/bin/printf unreachable); /usr/bin/printf unreachable", b"", 1)

    def test_traps_run_at_command_boundaries_and_on_exit(self):
        kill = "/bin/sh -c 'kill -%s $PPID'"
        self.run_source(f"trap '/usr/bin/printf \"<term:%s>\" $?' TERM; false; {kill % 'TERM'}; /usr/bin/printf '<after:%s>' $?; trap - TERM; trap",
                        b"<term:0><after:0>")
        self.run_source(f"trap '/usr/bin/printf int' INT HUP; {kill % 'INT'}; {kill % 'HUP'}; trap",
                        b"intinttrap -- '/usr/bin/printf int' HUP\ntrap -- '/usr/bin/printf int' INT\n")
        self.run_source(f"trap '' TERM; {kill % 'TERM'}; /bin/sleep 0.2; /usr/bin/printf survived", b"survived")
        self.run_source(f"trap 'exit 9' TERM; {kill % 'TERM'}; /bin/sleep 0.2; /usr/bin/printf unreachable", b"", 9)
        self.run_source("trap '/usr/bin/printf \"<exit:%s>\" $?' EXIT; /usr/bin/printf body; exit 4", b"body<exit:4>", 4)
        self.run_source("trap 'exit 7' EXIT; /usr/bin/printf body", b"body", 7)
        self.run_source("set -e; trap '/usr/bin/printf exit' 0; false", b"exit", 1)
        self.run_source("trap '/usr/bin/printf exit' EXIT; /bin/echo $((1 / 0))", b"exit", 2)
        # An untrapped fatal signal ends the shell without running the EXIT trap.
        self.run_source(f"trap '/usr/bin/printf exit' EXIT; {kill % 'TERM'}; /bin/sleep 0.2", b"", 128 + signal.SIGTERM)
        # Workers start without the parent's traps.
        self.run_source("trap '/usr/bin/printf parent' EXIT; (trap; /usr/bin/printf child:)", b"child:parent")
        self.run_source("trap 'if' TERM; /usr/bin/printf '%s' $?; trap x KILL; /usr/bin/printf ':%s' $?; trap x; /usr/bin/printf ':%s' $?", b"2:2:2")

    def test_interrupt_ends_a_batch_loop(self):
        self.run_source("while true; do /bin/sh -c 'kill -INT $PPID'; /bin/sleep 0.1; /usr/bin/printf once; done; /usr/bin/printf unreachable",
                        b"once", 128 + signal.SIGINT)

    def test_interactive_continuation_interrupt_and_trap(self):
        with PtyShell(SHELL) as shell:
            shell.send("if true\n")
            shell.expect(b"...> ")
            shell.send("then /bin/cat <<EOF\n")
            shell.expect(b"...> ")
            shell.send("heredoc $((6 * 7))\n")
            shell.expect(b"...> ")
            shell.send("EOF\n")
            shell.expect(b"...> ")
            shell.send("fi\n")
            self.assertIn(b"heredoc 42\r\n", shell.prompt())
            shell.send("while true; do /bin/sleep 30; done\n")
            eventually(lambda: children(shell.pid), "loop body not started")
            shell.send(b"\x03")
            shell.prompt()
            self.assertIn(b"<130>", shell.command("/usr/bin/printf '<%s>' $?"))
            self.assertEqual(children(shell.pid), [])
            shell.command("trap '/usr/bin/printf TRAPPED' TERM")
            os.kill(shell.pid, signal.SIGTERM)
            shell.expect(b"TRAPPED")
            shell.prompt()
            self.assertIn(b"<alive>", shell.command("/usr/bin/printf '<%s>' alive"))
            shell.send("trap '/usr/bin/printf BYE' EXIT\n")
            shell.prompt()
            shell.send(b"\x04")
            shell.expect(b"BYE")
            self.assertEqual(shell.wait(), 0)

    def test_positional_list_process_id_and_parameter_operators(self):
        self.run_source("""f() { /usr/bin/printf '<%s>' $@ "$@" $# ${1:-none} ${3:-none} ${#1}; for a in $@; do /usr/bin/printf '(%s)' $a; done; }
f 'two words' b; /usr/bin/printf '|'; g() { f $@ c; }; g a; /usr/bin/printf '|'; /usr/bin/printf '[%s]' x $@ end""",
                        b"<two words><b><two words><b><2><two words><none><9>(two words)(b)|<a><c><a><c><2><a><none><1>(a)(c)|[x][end]")
        self.run_source("""unset u; e=
/usr/bin/printf '%s\\n' "${u-d1} ${u:-d2} [${e-d3}] ${e:-d4 spaced}" "[${u+a1}] [${u:+a2}] [${e+a3}] [${e:+a4}] [${HOME:+a5}]"
/usr/bin/printf '%s\\n' "${u:=made} $u ${e:=filled} $e ${u:=ignored}" "${#u} ${nope:-$(/bin/echo sub) $((1 + 2)) ${u}}"
/usr/bin/printf '%s\\n' "${u:-$(/usr/bin/printf SHOULD-NOT-RUN >&2)}" ${u:+'kept * literal'}""",
                        b"d1 d2 [] d4 spaced\n[] [] [a3] [] [a5]\nmade made filled filled made\n4 sub 3 made\nmade\nkept * literal\n")
        self.run_source("p=$$; (/bin/test $$ = $p) && /bin/sh -c 'kill -0 $1' sh $$ && /usr/bin/printf same", b"same")
        for source in ("/bin/echo ${u:?}", "/bin/echo ${u?custom}", "e=; /bin/echo ${e:?}", "a=(1); /bin/echo ${a:-x}", "/bin/echo x$@"):
            with self.subTest(source=source):
                self.run_source(source + "; /bin/echo unreachable", b"", 2)
        process = launch("/bin/echo ${u:?custom message}")
        _, error = collect(process)
        self.assertIn(b"u: custom message", error)

    def test_case_groups_and_counted_loop_control(self):
        self.run_source("""v='*'
for word in abc 'x y' star none; do
  case $word in
    a*c) /usr/bin/printf glob ;;
    x | "x y") /usr/bin/printf :alt ;;
    $v) /usr/bin/printf :value-is-not-a-pattern ;;
    (star) /usr/bin/printf :literal
           /usr/bin/printf :multi ;;
    no?e) kept=$word
  esac
done
case none in a) false ;; esac; /usr/bin/printf ':%s:%s' $? $kept
false; case x in x) ;; esac; /usr/bin/printf ':%s' $?""", b"glob:alt:literal:multi:0:none:0")
        self.run_source("""{ /usr/bin/printf a; g=kept; }; /usr/bin/printf $g
{ /bin/echo piped; g=lost; } | /usr/bin/tr a-z A-Z; /usr/bin/printf $g
{ /usr/bin/printf hidden; h=redirected; } > /dev/null; /usr/bin/printf :$h
f() { { return 5; }; }; f; /usr/bin/printf ':%s' $?""", b"akeptPIPED\nkept:redirected:5")
        self.run_source("""for i in 1 2 3; do for j in a b c; do
  if /bin/test $j = b; then continue 2; fi
  if /bin/test $i = 3; then break 2; fi
  /usr/bin/printf $i$j
done; done; /usr/bin/printf ':%s' $?""", b"1a2a:0")
        for source in ("while true; do break 2; done", "while true; do break 0; done", "while true; do continue x; done", "esac", "case x in x) /bin/echo; ;; ;; esac"):
            with self.subTest(source=source):
                self.run_source(source + "; /bin/echo unreachable", b"", 2)

    def test_read_lines_fields_and_redirected_loops_keep_state(self):
        self.run_source("""/usr/bin/printf 'one\\n two  words \\n\\nlast' > $TMPDIR/swsh-read
n=0; while read line; do n=$((n + 1)); /usr/bin/printf '[%s]' $line; done < $TMPDIR/swsh-read
/usr/bin/printf ':%s:%s:%s' $n $line $?
/usr/bin/printf 'a  b\\tc d \\n' | { read first second rest; /usr/bin/printf ':%s|%s|%s' $first $second $rest; }
/usr/bin/printf 'only\\n' | { read -r first second; /usr/bin/printf ':%s|%s' $first $second; }
read direct <<EOF
from heredoc
EOF
/usr/bin/printf ':%s:%s' $direct $?
read empty < /dev/null; /usr/bin/printf ':%s[%s]' $? $empty
/bin/rm $TMPDIR/swsh-read""", b"[one][ two  words ][]:3:last:0:a|b|c d:only|:from heredoc:0:1[]",
                        )
        # A read leaves the rest of the input for the next command.
        self.run_source("/usr/bin/printf 'first\\nsecond\\n' | { read line; /bin/cat; }", b"second\n")
        self.run_source("read; /usr/bin/printf '%s' $?; read 1x; /usr/bin/printf ':%s' $?; read x <&-; /usr/bin/printf ':%s' $?", b"2:2:1")
        self.run_source("/usr/bin/printf 'a\\0b\\n' | { read x; /usr/bin/printf '%s[%s]' $? $x; }", b"2[]")
        self.run_source("set -e; /usr/bin/printf 'x\\n' | { while read line; do /usr/bin/printf $line; done; /usr/bin/printf :done; }", b"x:done")
        self.run_source("/bin/echo x | read y", b"", 2)

    def test_script_arguments_and_shift(self):
        def run(arguments, expected, status=0, **kwargs):
            process = subprocess.Popen([SHELL, *arguments], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       start_new_session=True, **kwargs)
            output, error = collect(process)
            self.assertEqual((process.returncode, output), (status, expected), error)

        with tempfile.TemporaryDirectory() as directory:
            script = os.path.join(directory, "script.swsh")
            Path(script).write_text("""/usr/bin/printf '<%s>' $# $1 $2 "$@"; /usr/bin/printf '|'
shift; /usr/bin/printf '<%s>' $# $1 ${3-unset} $@; /usr/bin/printf '|'
f() { shift 2; /usr/bin/printf '(%s)' $# $@; }; f a b c; /usr/bin/printf '<%s>' $#
/bin/echo $1 | /usr/bin/tr a-z A-Z
(/usr/bin/printf '%s:' $0 $2)
shift 3; /usr/bin/printf '%s' $?; shift; shift; shift; /usr/bin/printf ':%s:%s' $? $#
""")
            run([script, "one", "two words", "*"],
                b"<3><one><two words><one><two words><*>|<2><two words><unset><two words><*>|(1)(c)<2>TWO WORDS\n"
                + script.encode() + b":*:2:2:0")
        run(["-c", "/usr/bin/printf '<%s>' $0 $# $@", "name", "a", "b c"], b"<name><2><a><b c>")
        run(["-c", "/usr/bin/printf '<%s>' $0 $# $@ ${1-unset}"], b"<swsh><0><unset>")
        run(["-c", "set -u; /bin/echo $#; /bin/echo $1; /bin/echo unreachable", "name"], b"0\n", 2)
        run(["-c", "shift x; /usr/bin/printf '%s' $?; shift 1 2; /usr/bin/printf '%s' $?", "name", "a"], b"22")
        run(["-c", "/bin/echo x | shift", "name", "a"], b"", 2)
        for arguments in (["-c"], ["-x"], ["-i", "extra"]):
            with self.subTest(arguments=arguments):
                run(arguments, b"", 2)

    def test_arithmetic_assignment_updates_the_current_shell(self):
        self.run_source("""x=5; /usr/bin/printf '%s ' $x $((x = x + 2)) $x $((x++)) $x $((++x)) $((x--)) $((--x)) $x
/usr/bin/printf '%s ' $((y = z = 3)) $y $z $((y += 4)) $((y <<= 2)) $((y %= 5)) $((y == 3 ? (x = 1) : (x = 2))) $x $((q = 2, q * 4))""",
                        b"5 7 7 7 8 9 9 7 7 3 3 3 7 28 3 1 1 8 ")
        self.run_source("""a=(1 2 3); /usr/bin/printf '%s ' $((a[1] += 10)) $((a[0]++)) ${a[0]} $((a[3] = 9)) ${#a[@]}
i=0; a[i++]=zero; a[i++]=$i; /usr/bin/printf '%s ' $i ${a[@]}""", b"12 1 2 9 4 2 zero 2 3 9 ")
        self.run_source("a=(x y); s=scalar; i=0; trap '/usr/bin/printf \"%s:%s\" $i ${a[0]}' EXIT; a[i++]=changed s[0]=bad", b"0:x", 2)
        self.run_source("""i=0; while /bin/test $((i++)) -lt 3; do /usr/bin/printf $i; done; : $((n += 5)) $((n *= 2))
/usr/bin/printf ':%s:%s:%s' $n "$n$((n = 1))$n" ${u:-$((n = 7))}$n
v=1; /usr/bin/printf ':%s:%s' $(/bin/echo $((v = 5))) $v
f() { $((count += 1)); }; /bin/cat <<EOF
:$((h = 4))$h
EOF""", b"123:10:1011:77:5:1:44\n")
        for source in ("a=(1); /bin/echo $((a = 2))", "/bin/echo $((5 = 1))", "a=(1); /bin/echo $((a[2] = 1))",
                       "s=x; /bin/echo $((s[0] = 1))", "w=abc; /bin/echo $((w += 1))", "/bin/echo $(($x = 1))",
                       "set -u; /bin/echo $((unset_name++))"):
            with self.subTest(source=source):
                self.run_source(source + "; /bin/echo unreachable", b"", 2)

    def test_local_restores_the_callers_variables(self):
        self.run_source("""g=global; e=exp; export e; l=(1 2)
inner() { local g=deeper; /usr/bin/printf 'inner:%s ' $g; }
f() { local g=inner e h l=scalar; /usr/bin/printf 'in:%s[%s][%s]%s ' $g ${e-unset} ${h-unset} $l; h=set; g2=leak; inner; g=changed; /usr/bin/printf 'in2:%s ' $g; }
f; /usr/bin/printf 'out:%s:%s:[%s]:%s:%s ' $g $e ${h-unset} $g2 ${#l[@]}; /usr/bin/env | /usr/bin/grep '^e='""",
                        b"in:inner[unset][unset]scalar inner:deeper in2:changed out:global:exp:[unset]:leak:2 e=exp\n")
        self.run_source("""fact() { local n=$1; if /bin/test $n -le 1; then r=1; else fact $((n - 1)); r=$((r * n)); fi; }
fact 5; /usr/bin/printf '%s:[%s]' $r ${n-unset}
early() { local v=1; return 3; }; v=kept; early; /usr/bin/printf ':%s:%s' $? $v
twice() { local t=1; local t=2 PATH=/nonexistent; /usr/bin/printf ':%s' $t; }; t=outer; twice; /usr/bin/printf ':%s' $t; /bin/echo :path-restored
piped() { local p=worker; /bin/echo $p; }; piped | /usr/bin/tr a-z A-Z""", b"120:[unset]:3:kept:2:outer:path-restored\nWORKER\n")
        for source in ("local x=1", "f() { local 1x; }; f", "f() { local; }; f", "f() { local a=1 b-c; /bin/echo $a; }; f",
                       "f() { /bin/echo x | local y; }; f"):
            with self.subTest(source=source):
                self.run_source(source + "; /bin/echo unreachable", b"", 2)

    def test_bracket_patterns_match_paths_and_case_words(self):
        with tempfile.TemporaryDirectory() as directory:
            for name in ("a1", "a2", "b1", "c.txt", "]x"):
                Path(directory, name).touch()

            def run(source, expected, status=0):
                process = launch(source, cwd=directory)
                output, error = collect(process)
                self.assertEqual((process.returncode, output), (status, expected), error)

            run("""/usr/bin/printf '<%s>' [ab]1 [!a]? [!ab]? a[1-2] "[ab]1" '['ab] [ ] x[ y] a[]1] []]x ?[!0-9]*""",
                b"<a1><b1><]x><b1><]x><a1><a2><[ab]1><[ab]><[><]><x[><y]><a1><]x><]x><c.txt>")
            run("v='[ab]1'; /usr/bin/printf '<%s>' $v ${v} \"$v\" ${u:-[ab]1}; /bin/[ -f a1 ] && /usr/bin/printf ok",
                b"<[ab]1><[ab]1><[ab]1><[ab]1>ok")
            for source in ("/bin/echo [xyz]1", "/bin/echo [$v]", "/bin/echo [a\\]]", "/bin/echo [[:alpha:]]1",
                           "/bin/echo a['1']", "/bin/echo [^a]1"):
                with self.subTest(source=source):
                    run(source + "; /bin/echo unreachable", b"", 2)
        self.run_source("""v='[ab]'
for word in b d 5 ']' '[ab]' -; do
  case $word in
    [ac]) /usr/bin/printf no ;;
    [[:digit:]]) /usr/bin/printf class: ;;
    []x]) /usr/bin/printf bracket: ;;
    $v) /usr/bin/printf value-is-literal: ;;
    [a-c]|[!a-z]) /usr/bin/printf range-or-negated: ;;
    *) /usr/bin/printf other: ;;
  esac
done""", b"range-or-negated:other:class:bracket:value-is-literal:range-or-negated:")

    def test_read_is_interruptible_and_honors_shutdown(self):
        read, write = os.pipe()
        process = launch("read line; /usr/bin/printf unreachable", stdin=read)
        os.close(read)
        time.sleep(0.3)
        os.kill(process.pid, signal.SIGTERM)
        output, _ = collect(process)
        os.close(write)
        self.assertEqual((process.returncode, output), (128 + signal.SIGTERM, b""))
        with PtyShell(SHELL) as shell:
            shell.send("while read line; do /usr/bin/printf '<%s>' $line; done\n")
            # Input typed before the command starts belongs to the line editor.
            shell.expect(b"\x1b]133;C\x07")
            shell.send("typed\n")
            shell.expect(b"<typed>")
            # Until the body's job is reaped it, not the shell, owns the terminal
            # and would receive the interrupt.
            time.sleep(0.3)
            shell.send(b"\x03")
            shell.prompt()
            self.assertIn(b"<130>", shell.command("/usr/bin/printf '<%s>' $?"))

    def test_functions_arguments_state_and_pipeline_isolation(self):
        self.run_source("f() { x=$1; /usr/bin/printf '<%s>:%s\\n' $x $#; }; f 'two words'; /usr/bin/printf '%s\\n' $x; f child | /bin/cat; /usr/bin/printf '%s\\n' $x",
                        b"<two words>:1\ntwo words\n<child>:1\ntwo words\n")

    def test_subshell_nested_state_and_redirects(self):
        self.run_source("x=outer; (x=inner; (/usr/bin/printf '%s' $x)); /usr/bin/printf ':%s' $x", b"inner:outer")

    def test_substitution_scalar_nested_and_trailing_newlines(self):
        self.run_source("""x=$(/usr/bin/printf 'two words*\\n\\n'); /usr/bin/printf '<%s>' $x; /usr/bin/printf '<%s>' "$(/usr/bin/printf '%s' $(/usr/bin/printf nested))" """, b"<two words*><nested>")

    def test_substitution_large_output_and_failure(self):
        self.run_source("""/usr/bin/printf '%s' $(/usr/bin/python3 -c 'print("x" * 100000)')""", b"x" * 100000)
        self.run_source("/bin/echo $(false)", b"", 2)
        self.run_source("""/bin/echo $(/usr/bin/python3 -c 'import os; os.write(1, b"x" * 1100000)')""", b"", 2)

    def test_programmable_completion_and_provider_isolation(self):
        with PtyShell(SHELL) as shell:
            shell.command("complete echo 'hello world'")
            shell.send("echo he\t\n")
            self.assertIn(b"hello world", shell.prompt())
            shell.command("provider() { x=changed; /usr/bin/printf 'dynamic value\\n'; return 0; }; complete --function echo provider")
            shell.send("echo dyn\t\n")
            self.assertIn(b"dynamic value", shell.prompt())
            self.assertIn(b"<>", shell.command("/usr/bin/printf '<%s>' $x"))

    def test_function_return_recursion_and_redirect_state(self):
        self.run_source("f() { return 7; /bin/echo unreachable; }; f; /usr/bin/printf '%s' $?", b"7")
        self.run_source("f() { f; }; f", b"", 2)
        with tempfile.TemporaryDirectory() as root:
            output = Path(root, "output")
            self.run_source(f"f() {{ x=changed; /bin/echo external; pwd; }}; f >'{output}'; /usr/bin/printf '%s' $x", b"changed")
            self.assertTrue(output.read_bytes().startswith(b"external\n"))
        self.run_source("outer() { inner() { return 3; }; inner ignored; /usr/bin/printf '%s' $1; }; outer kept", b"kept")

    def test_subshell_cwd_exit_and_function_snapshot(self):
        self.run_source("f() { /bin/echo inherited; }; (cd /; f; exit 4); /usr/bin/printf '%s' $?", b"inherited\n4")
        self.run_source("f() { return 9; }; f | /bin/cat; /usr/bin/printf '%s' $?", b"0")
        self.run_source("/bin/echo hi | ( /bin/cat; )", b"hi\n")

    def test_substitution_raw_bytes_nul_and_single_evaluation(self):
        self.run_source("""/usr/bin/printf '%s' $(/usr/bin/python3 -c 'import os; os.write(1, bytes([255]))')""", b"\xff")
        self.run_source("""/usr/bin/printf '%s' $(/usr/bin/python3 -c 'import os; os.write(1, bytes([0]))')""", b"", 2)
        with tempfile.TemporaryDirectory() as root:
            marker = Path(root, "count")
            self.run_source(f"x=$(/bin/echo once >>'{marker}'; /bin/echo value); /usr/bin/printf '%s' $x", b"value")
            self.assertEqual(marker.read_bytes(), b"once\n")
        self.run_source("false && /bin/echo $(/bin/echo unreachable); true", b"")

    def test_compound_job_stop_resume_and_interrupt(self):
        with PtyShell(SHELL) as shell:
            shell.send("(/bin/sleep 30)\n")
            shell.foreground_job()
            shell.send(b"\x1a")
            self.assertIn(b"stopped", shell.prompt())
            shell.send("fg\n")
            shell.foreground_job()
            shell.send(b"\x03")
            shell.prompt()

    def test_compound_child_self_stop_propagates_to_outer_job(self):
        with PtyShell(SHELL) as shell:
            shell.send("(/bin/sh -c 'kill -STOP $$; echo resumed')\n")
            self.assertIn(b"stopped", shell.prompt())
            self.assertIn(b"resumed", shell.command("fg"))

    def test_completion_provider_timeout_preserves_prompt_and_status(self):
        with PtyShell(SHELL) as shell:
            shell.command("provider() { /bin/sleep 30; }; complete --function echo provider; false")
            started = time.monotonic()
            shell.send("echo prefix\t")
            time.sleep(1.3)
            shell.send(b"\x15/usr/bin/printf '<%s>' $?\n")
            output = shell.prompt()
            self.assertIn(b"<1>", output)
            self.assertLess(time.monotonic() - started, 5)



if __name__ == "__main__":
    unittest.main()
