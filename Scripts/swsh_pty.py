"""PTY fixture for isolated native-shell job-control checks."""
import errno
import os
import pty
import select
import signal
import tempfile
import time

PROMPT_MARKER = b"\x1b]133;A\x07"


class PtyShell:
    def __init__(self, executable, startup=None, blocked_signals=()):
        self.home = tempfile.TemporaryDirectory()
        if startup is not None:
            with open(os.path.join(self.home.name, ".swshrc"), "w") as file:
                file.write(startup)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            environment = os.environ | {"HOME": self.home.name, "TERM": "xterm-256color"}
            environment.pop("SWSH_TERMINAL_METADATA", None)
            if blocked_signals:
                signal.pthread_sigmask(signal.SIG_BLOCK, blocked_signals)
            # pty.fork keeps descriptors inherited from the test runner (CI
            # runners leak some); close them as subprocess does, so a shell's
            # `exec` sees only what the shell itself opened.
            for fd in [int(name) for name in os.listdir("/dev/fd")]:
                if fd > 2:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
            os.execve(executable, [executable, "-i"], environment)
        self.buffer = b""
        self.exited = False
        try:
            self.prompt()
        except BaseException:
            self.close()
            raise

    def send(self, data):
        os.write(self.fd, data if isinstance(data, bytes) else data.encode())

    def expect(self, token, timeout=6):
        deadline = time.monotonic() + timeout
        while token not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"PTY timeout waiting for {token!r}: {self.buffer[-3000:]!r}")
            if not select.select([self.fd], [], [], remaining)[0]:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    data = b""
                else:
                    raise
            if not data:
                raise AssertionError(f"PTY ended waiting for {token!r}: {self.buffer[-3000:]!r}")
            self.buffer += data
        end = self.buffer.index(token) + len(token)
        result, self.buffer = self.buffer[:end], self.buffer[end:]
        return result

    def prompt(self):
        output = self.expect(PROMPT_MARKER)
        return output + self.expect(b"swsh> ")

    def command(self, source):
        self.send(source + "\n")
        return self.prompt()

    def drain_available(self):
        if self.fd < 0:
            return
        while select.select([self.fd], [], [], 0)[0]:
            try:
                data = os.read(self.fd, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    return
                raise
            if not data:
                return
            self.buffer += data

    def foreground_job(self):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            self.drain_available()
            group = os.tcgetpgrp(self.fd)
            if group != self.pid and group > 0:
                return group
            time.sleep(0.005)
        raise AssertionError("job did not acquire the terminal")

    def wait(self, timeout=6):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.drain_available()
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.exited = True
                return os.waitstatus_to_exitcode(status)
            time.sleep(0.01)
        raise AssertionError("shell did not exit")

    def hangup(self):
        os.close(self.fd)
        self.fd = -1
        return self.wait()

    def close(self):
        try:
            if not self.exited:
                os.kill(self.pid, signal.SIGTERM)
                try:
                    self.wait()
                except AssertionError:
                    group = os.tcgetpgrp(self.fd)
                    if group > 0 and group != self.pid:
                        os.killpg(group, signal.SIGKILL)
                    os.kill(self.pid, signal.SIGKILL)
                    self.wait()
        finally:
            if self.fd >= 0:
                os.close(self.fd)
            self.home.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
