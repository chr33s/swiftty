#!/usr/bin/env python3
"""Copy and verify a sibling app, then atomically publish it on macOS."""

import ctypes
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
from xml.parsers.expat import ExpatError


INTERRUPTS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
interrupted_signal = 0
# macOS SDK sys/stdio.h; these flags cannot be combined.
RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004
CODE_INFO_LIMIT = 65536


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def interrupt(signum, frame):
    global interrupted_signal
    if interrupted_signal == 0:
        interrupted_signal = signum


def check_interrupted():
    if interrupted_signal:
        raise Interrupted(interrupted_signal)


def run_checked(command, output=None):
    check_interrupted()
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, start_new_session=True,
                               stdout=output, stderr=subprocess.STDOUT if output is not None else None)
    try:
        while True:
            check_interrupted()
            try:
                status = process.wait(timeout=0.1)
                break
            except subprocess.TimeoutExpired:
                continue
        check_interrupted()
        if status != 0:
            raise subprocess.CalledProcessError(status, command)
    finally:
        # Keep the owned child uncollected until its group is killed on
        # interruption. Repeated signals cannot abandon kill/reap cleanup.
        if process.returncode is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def validate_app(app, expected_team):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if not isinstance(info, dict) or info.get("CFBundleIdentifier") != "com.chr33s.swiftty" \
            or info.get("CFBundleExecutable") != "swiftty":
        raise ValueError("replacement must be the Swiftty app bundle")
    for name in ("swiftty", "swiftmux-agent", "swmux-launcher", "swmux", "swsh"):
        executable = app / "Contents/MacOS" / name
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise ValueError(f"replacement executable missing or not executable: {name}")
    run_checked(["codesign", "--verify", "--strict", str(app)])
    with tempfile.TemporaryFile() as output:
        run_checked(["codesign", "-dv", str(app)], output=output)
        output.seek(0)
        data = output.read(CODE_INFO_LIMIT + 1)
    if len(data) > CODE_INFO_LIMIT:
        raise ValueError("replacement signing metadata exceeds limit")
    teams = [line.partition("=")[2] for line in data.decode("utf-8").splitlines()
             if line.startswith("TeamIdentifier=")]
    if len(teams) != 1:
        raise ValueError("replacement signing team is unavailable")
    team = "" if teams[0] == "not set" else teams[0]
    if team != expected_team:
        raise ValueError("replacement signing team changed after the restart decision")


def atomic_publish(parent_fd, staged_name, destination_name, replacing):
    rename = ctypes.CDLL(None, use_errno=True).renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    flags = RENAME_SWAP if replacing else RENAME_EXCL
    if rename(parent_fd, os.fsencode(staged_name), parent_fd, os.fsencode(destination_name), flags) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination_name)


def install_app(source, destination, expected_team):
    if destination.name != "Swiftty.app":
        raise ValueError("destination must be named Swiftty.app")
    parent = destination.parent.resolve(strict=True)
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    staging = None
    try:
        try:
            os.stat(destination.name, dir_fd=parent_fd, follow_symlinks=False)
            replacing = True
        except FileNotFoundError:
            replacing = False
        staging = Path(tempfile.mkdtemp(prefix=".Swiftty-install-", dir=parent))
        app = staging / destination.name
        run_checked(["ditto", str(source), str(app)])
        validate_app(app, expected_team)
        # The commit is one syscall: failure leaves both names unchanged.
        # Once successful, cleanup removes the swapped-out previous app.
        check_interrupted()
        atomic_publish(parent_fd, str(app.relative_to(parent)), destination.name, replacing)
    finally:
        try:
            if staging is not None:
                try:
                    shutil.rmtree(staging)
                except OSError as error:
                    print(f"install.sh: cannot clean staging directory {staging}: {error}", file=sys.stderr)
        finally:
            os.close(parent_fd)


def main():
    if len(sys.argv) != 4 or sys.platform != "darwin":
        print("usage: install-app.py SOURCE Swiftty.app EXPECTED_TEAM (macOS)", file=sys.stderr)
        return 64
    for signum in INTERRUPTS:
        signal.signal(signum, interrupt)
    try:
        install_app(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
        return 0
    except Interrupted as error:
        print("install.sh: app replacement interrupted", file=sys.stderr)
        return 128 + error.signum
    except (OSError, ValueError, ExpatError, subprocess.CalledProcessError) as error:
        print(f"install.sh: cannot replace app: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
