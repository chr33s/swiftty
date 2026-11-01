"""Failure and interaction tests for the native language extensions.

Run through Scripts/test-swsh.py, which supplies the executable.
Process inventories are taken before fixture teardown so teardown cannot hide leaks.
"""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from swsh_pty import PtyShell

SHELL = None


def configure(executable):
    global SHELL
    SHELL = executable


def eventually(predicate, message, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError(message)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True  # Includes zombies: an unreaped process is not successful cleanup.
    except ProcessLookupError:
        return False


def children(pid):
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid="], text=True)
    return sorted(int(row.split()[0]) for row in rows.splitlines()
                  if len(row.split()) == 2 and int(row.split()[1]) == pid)


def descriptors(pid):
    output = subprocess.check_output(["/usr/sbin/lsof", "-a", "-p", str(pid), "-Ff"], text=True)
    return sorted(line[1:] for line in output.splitlines() if line.startswith("f") and line[1:].isdigit())


# This program publishes readiness only after installing its TERM/HUP policy.
# Gate files keep overflow behind the parent's process-inventory snapshot.
LEAF = r'''
import json, os, signal, sys, time
from pathlib import Path
marker, gate, mode = map(str, sys.argv[1:])
signal.signal(signal.SIGHUP, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(marker).write_text(json.dumps([os.getpid(), os.getppid()]))
while not Path(gate).exists(): time.sleep(.005)
if mode == 'overflow':
    try:
        data = b'x' * (1024 * 1024 + 1)
        while data:
            written = os.write(1, data)
            data = data[written:]
    except BrokenPipeError: pass
while True: time.sleep(1)
'''


class LanguageInteractionTests(unittest.TestCase):
    def run_source(self, source, expected=b"", status=0, cwd=None):
        process = subprocess.Popen([SHELL, "-c", source], cwd=cwd, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        try:
            output, error = process.communicate(timeout=10)
            self.assertEqual(process.returncode, status, error)
            self.assertEqual(output, expected, error)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()

    def test_nested_function_redirect_order_and_restoration(self):
        with tempfile.TemporaryDirectory() as root:
            outer, inner = Path(root, "outer"), Path(root, "inner")
            source = (f"inner() {{ /bin/sh -c 'printf out; printf err >&2'; x=kept; }}; "
                      f"outer() {{ inner >'{inner}' 2>&1; /bin/echo after; }}; "
                      f"outer >'{outer}'; /usr/bin/printf '%s' $x")
            self.run_source(source, b"kept")
            self.assertEqual(inner.read_bytes(), b"outerr")
            self.assertEqual(outer.read_bytes(), b"after\n")
            self.run_source(f"inner() {{ /bin/sh -c 'printf out; printf err >&2'; }}; inner 2>&1 >'{inner}'", b"err")
            self.assertEqual(inner.read_bytes(), b"out")

    def test_subshell_cwd_does_not_change_parent(self):
        with tempfile.TemporaryDirectory() as root:
            physical = os.path.realpath(root).encode()
            self.run_source("(cd /; pwd); pwd", b"/\n" + physical + b"\n", cwd=root)
            self.run_source("f() { cd /; }; f; pwd", b"/\n", cwd=root)

    def test_substitution_redirect_and_single_evaluation(self):
        with tempfile.TemporaryDirectory() as root:
            target, count = Path(root, "two words"), Path(root, "count")
            self.run_source(f"/bin/echo value >$(/bin/echo once >>'{count}'; /bin/echo '{target}')")
            self.assertEqual(target.read_bytes(), b"value\n")
            self.assertEqual(count.read_bytes(), b"once\n")

    def test_background_function_preserves_parent_state(self):
        with PtyShell(SHELL) as shell:
            marker = Path(shell.home.name, "done")
            shell.command(f"x=parent; f() {{ x=child; cd /; /usr/bin/printf '%s' $x >'{marker}'; }}; f &")
            eventually(lambda: marker.exists() and marker.read_bytes() == b"child", "function did not finish")
            output = shell.command("/usr/bin/printf '<%s>' $x; pwd")
            self.assertIn(b"<parent>" + os.getcwd().encode(), output)
            eventually(lambda: not children(shell.pid), "background worker was not reaped")

    def test_capture_exact_byte_limit(self):
        for count, status in ((1024 * 1024, 0), (1024 * 1024 + 1, 2)):
            with self.subTest(count=count):
                code = f"import os; data=b'x'*{count}; os.write(1,data)"
                self.run_source(f"value=$({shlex.quote(sys.executable)} -c {shlex.quote(code)})", status=status)

    def test_compound_repeated_stop_resume_preserves_pid(self):
        with PtyShell(SHELL) as shell:
            marker = Path(shell.home.name, "worker-pid")
            code = f"echo $$ >'{marker}'; kill -STOP $$; kill -STOP $$; kill -STOP $$; echo finished"
            shell.send(f"(/bin/sh -c {shlex.quote(code)})\n")
            self.assertIn(b"stopped", shell.prompt())
            pid = int(marker.read_text())
            for _ in range(2):
                self.assertIn(b"stopped", shell.command("fg"))
                self.assertTrue(alive(pid))
                self.assertEqual(int(marker.read_text()), pid)
            self.assertIn(b"finished", shell.command("fg"))
            eventually(lambda: not alive(pid) and not children(shell.pid), "resumed job not reaped")


class LanguageLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.marker = Path(self.root.name, "ready")
        self.gate = Path(self.root.name, "gate")
        self.tracked = []

    def tearDown(self):
        # Cleanup is deliberately AFTER assertions. Retain only this fixture's PIDs.
        for pid in self.tracked:
            if alive(pid):
                try: os.kill(pid, signal.SIGKILL)
                except ProcessLookupError: pass
        self.root.cleanup()

    def leaf(self, mode):
        return " ".join(map(shlex.quote, [sys.executable, "-c", LEAF,
                                          str(self.marker), str(self.gate), mode]))

    def ready_tree(self, root, shell=None):
        def ready():
            if shell is not None: shell.drain_available()
            try: return json.loads(self.marker.read_text())
            except (FileNotFoundError, json.JSONDecodeError): return None
        leaf, _ = eventually(ready, "leaf never published readiness")
        rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid="], text=True)
        parents = {int(row.split()[0]): int(row.split()[1]) for row in rows.splitlines()}
        current = leaf
        while current != root:
            self.tracked.append(current)
            self.assertIn(current, parents, "tree changed before readiness snapshot")
            current = parents[current]
            self.assertGreater(current, 1, "worker escaped the shell before cleanup")
        self.assertGreaterEqual(len(self.tracked), 3, "fixture did not create nested supervisors")
        return leaf

    def assert_retired(self):
        eventually(lambda: all(not alive(pid) for pid in self.tracked),
                   f"descendants remained alive or unreaped: {self.tracked}", timeout=1)

    def test_nested_term_resistant_batch_shutdown_reaps_tree(self):
        for sig in (signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig):
                self.marker.unlink(missing_ok=True)
                process = subprocess.Popen([SHELL, "-c", f"(({self.leaf('wait')}))"],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                try:
                    self.ready_tree(process.pid)
                    process.send_signal(sig)
                    status = process.wait(timeout=6)
                    self.assert_retired()
                    output, error = process.communicate(timeout=1)
                    self.assertEqual(status, 128 + sig, error)
                finally:
                    for pid in self.tracked:
                        if alive(pid):
                            try: os.kill(pid, signal.SIGKILL)
                            except ProcessLookupError: pass
                    if process.poll() is None: os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=2)

    def test_oversized_source_snapshot_does_not_launch_or_leak(self):
        with PtyShell(SHELL) as shell:
            before = descriptors(shell.pid)
            code = "import sys; sys.stdout.buffer.write(b'x' * (1024 * 1024))"
            source = f"large=$({shlex.quote(sys.executable)} -c {shlex.quote(code)}); second=$large; third=$large; (true)"
            self.assertIn(b"launcher payload too large", shell.command(source))
            self.assertIn(b"<1>", shell.command("/usr/bin/printf '<%s>' $?"))
            self.assertEqual(children(shell.pid), [])
            self.assertEqual(descriptors(shell.pid), before)

    def test_nested_exec_replacement_remains_subject_to_escalation(self):
        process = subprocess.Popen([SHELL, "-c", f"(((exec {self.leaf('wait')})))"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            self.ready_tree(process.pid)
            started = time.monotonic()
            process.send_signal(signal.SIGTERM)
            status = process.wait(timeout=6)
            self.assert_retired()
            output, error = process.communicate(timeout=1)
            self.assertEqual(status, 128 + signal.SIGTERM, error)
            self.assertLess(time.monotonic() - started, 5)
        finally:
            for pid in self.tracked:
                if alive(pid):
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
            if process.poll() is None: os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=2)

    def test_substitution_overflow_reaps_nested_tree_and_restores_fds(self):
        with PtyShell(SHELL) as shell:
            before = descriptors(shell.pid)
            shell.send(f"x=$(({self.leaf('overflow')}))\n")
            self.ready_tree(shell.pid, shell)
            self.gate.touch()
            self.assertIn(b"exceeds 1 MiB", shell.prompt())
            self.assert_retired()
            self.assertEqual(children(shell.pid), [])
            self.assertEqual(descriptors(shell.pid), before)

    def test_provider_timeout_reaps_nested_tree_without_killing_other_job(self):
        with PtyShell(SHELL) as shell:
            shell.command("/bin/sleep 30 &")
            unrelated = eventually(lambda: children(shell.pid), "background job not started")
            before = descriptors(shell.pid)
            shell.command(f"provider() {{ ({self.leaf('wait')}); }}; complete --function echo provider; false")
            shell.send("echo prefix\t")
            self.ready_tree(shell.pid, shell)
            shell.send(b"\x15/usr/bin/printf '<%s>' $?\n")
            self.assertIn(b"<1>", shell.prompt())
            self.assert_retired()
            self.assertEqual(children(shell.pid), unrelated)
            self.assertTrue(all(alive(pid) for pid in unrelated))
            self.assertEqual(descriptors(shell.pid), before)

    def test_nested_term_resistant_hangup_reaps_tree(self):
        with PtyShell(SHELL) as shell:
            shell.send(f"(({self.leaf('wait')}))\n")
            self.ready_tree(shell.pid, shell)
            self.assertEqual(shell.hangup(), 128 + signal.SIGHUP)
            self.assert_retired()


def command_output(output):
    return output.split(b"\x1b]133;C\x07", 1)[1].split(b"\x1b]133;D;", 1)[0]


class CompletionContractTests(unittest.TestCase):
    def install(self, shell, code):
        shell.command(f"provider() {{ {shlex.quote(sys.executable)} -c {shlex.quote(code)}; }}; complete --function echo provider")

    def test_provider_receives_token_and_line_and_preserves_status(self):
        with PtyShell(SHELL) as shell:
            marker = Path(shell.home.name, "arguments")
            shell.command(f"provider() {{ /usr/bin/printf '%s\\n%s\\n' $1 $2 >'{marker}'; /bin/echo prefixed; }}; complete --function echo provider; false")
            shell.send("echo pre\t")
            eventually(lambda: marker.exists(), "provider did not run")
            self.assertEqual(marker.read_bytes(), b"pre\necho pre\n")
            shell.send(b"\x15/usr/bin/printf '<%s>' $?\n")
            self.assertIn(b"<1>", shell.prompt())

    def test_provider_exact_output_limit_and_invalid_candidates(self):
        cases = [
            ("b'\\n' * (1024 * 1024 - 3) + b'ok\\n'", b"ok"),
            ("b'\\n' * (1024 * 1024 - 2) + b'ok\\n'", b"o"),
            ("b'o\\xff\\n'", b"o"),
            ("b'o\\0\\n'", b"o"),
            ("b'other\\rname\\n'", b"o"),
        ]
        with PtyShell(SHELL) as shell:
            for expression, expected in cases:
                with self.subTest(expression=expression):
                    self.install(shell, f"import os; os.write(1, {expression})")
                    shell.send("echo o\t\n")
                    output = shell.prompt()
                    self.assertEqual(command_output(output), expected + b"\r\n")
                    self.assertEqual(children(shell.pid), [])

    def test_provider_candidates_are_data_not_syntax(self):
        with PtyShell(SHELL) as shell:
            marker = Path(shell.home.name, "must-not-execute")
            candidate = f"prefix; /usr/bin/touch {marker}"
            self.install(shell, f"print({candidate!r})")
            shell.send("echo pre\t\n")
            output = shell.prompt()
            self.assertIn(candidate.encode(), output)
            self.assertFalse(marker.exists())

    def test_failure_and_quoted_input_do_not_mutate_or_run_provider(self):
        with PtyShell(SHELL) as shell:
            marker = Path(shell.home.name, "called")
            shell.command(f"provider() {{ /usr/bin/touch '{marker}'; /bin/echo other; return 7; }}; complete --function echo provider")
            shell.send("echo o\t\n")
            self.assertEqual(command_output(shell.prompt()), b"o\r\n")
            self.assertTrue(marker.exists())
            marker.unlink()
            shell.send("echo 'o\t'\n")
            shell.prompt()
            self.assertFalse(marker.exists())

    def test_repeated_providers_leave_stable_fds_and_no_children(self):
        with PtyShell(SHELL) as shell:
            self.install(shell, "print('other')")
            before = descriptors(shell.pid)
            for _ in range(12):
                shell.send("echo o\t\n")
                self.assertEqual(command_output(shell.prompt()), b"other\r\n")
            self.assertEqual(children(shell.pid), [])
            self.assertEqual(descriptors(shell.pid), before)
