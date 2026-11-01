"""Isolated foreground/background terminal-mode fixture, invoked by test-swsh.py."""
import os
import signal
import sys
import termios
import tty

tty.setraw(0)
raw = termios.tcgetattr(0)
os.write(1, b"RAW_READY\n")
os.kill(os.getpid(), signal.SIGTSTP)
if sys.argv[1] == "bg":
    current = termios.tcgetattr(0)
    if not current[3] & termios.ISIG:
        os.write(1, b"BG_CHANGED_MODES\n")
        sys.exit(61)
    os.write(1, b"BG_EDITOR_MODES\n")
    os.kill(os.getpid(), signal.SIGSTOP)
if termios.tcgetattr(0) != raw:
    os.write(1, b"FG_MODES_WRONG\n")
    sys.exit(62)
os.write(1, b"FG_MODES_RESTORED\n")
