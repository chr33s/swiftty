"""Load the test probe only after creating an isolated controlling terminal."""
import ctypes
import os
import pty
import select
import signal
import sys
import subprocess
import time

if len(sys.argv) == 3:
    developer = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], text=True).strip() + "/Developer"
    toolchain = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip().rsplit("/usr/bin/", 1)[0]
    environment = dict(os.environ)
    environment["DYLD_FRAMEWORK_PATH"] = developer + "/Library/Frameworks:" + developer + "/Library/PrivateFrameworks"
    environment["DYLD_LIBRARY_PATH"] = developer + "/usr/lib:" + toolchain + "/usr/lib/swift/macosx"
    os.execve(sys.executable, [sys.executable, *sys.argv, "configured"], environment)

pid, master = pty.fork()
if pid == 0:
    library = ctypes.CDLL(sys.argv[1])
    probe = library.swsh_runtime_fault_probe
    probe.argtypes = [ctypes.c_char_p]
    probe.restype = ctypes.c_int
    status = probe(sys.argv[2].encode())
    ctypes.CDLL(None).fflush(None)
    os._exit(status)

deadline = time.monotonic() + 10
status = None
try:
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.05)[0]:
            try:
                data = os.read(master, 65536)
                if data:
                    os.write(1, data)
            except OSError:
                pass
        result, value = os.waitpid(pid, os.WNOHANG)
        if result:
            status = value
            break
    if status is None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        raise RuntimeError("runtime probe exceeded deadline")
    sys.exit(os.waitstatus_to_exitcode(status))
finally:
    os.close(master)
