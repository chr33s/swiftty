"""Reject successful process exits that leave Swift Testing runs incomplete."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "check_test_output", ROOT / "Scripts/check-test-output.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
START = "◇ Test run started.\n"
PASS = "✔ Test run with 2 tests in 1 suite passed after 0.012 seconds.\n"


class TestOutputCompletionTests(unittest.TestCase):
    def test_all_completed_runs_pass(self):
        MODULE.check_suite_completion(START + PASS + START + PASS, "suite")
        MODULE.check_suite_completion(
            START + "✔ Test run with 1 test passed after 0.001 seconds.\n",
            "single",
        )

    def test_truncated_target_fails_despite_other_successful_summaries(self):
        # The app target may exit 0 halfway through a test, then SwiftPM runs
        # the remaining targets. A passing summary anywhere is insufficient.
        for incomplete in range(8):
            with self.subTest(incomplete=incomplete):
                output = "".join(
                    START + ("◇ Test nativeToolbar() started.\n" if i == incomplete else PASS)
                    for i in range(8)
                )
                with self.assertRaisesRegex(RuntimeError, "8 started.*7 passing"):
                    MODULE.check_suite_completion(output, "suite")

    def test_known_issue_runs_pass(self):
        for count in ["1 known issue", "3 known issues"]:
            with self.subTest(count=count):
                MODULE.check_suite_completion(
                    START + "\x1b[90m━\x1b[0m Test run with 1222 tests in 116 suites "
                    f"passed after 89.960 seconds with {count}.\n",
                    "suite",
                )

    def test_known_issue_marker_requires_known_issue_summary(self):
        output = START + "━ Test run with 2 tests in 1 suite passed after 0.012 seconds.\n"
        with self.assertRaises(RuntimeError):
            MODULE.check_suite_completion(output, "suite")

    def test_missing_or_unmatched_reports_fail(self):
        for output in ["", "Build complete!\n", START, PASS, START + PASS + PASS]:
            with self.subTest(output=output), self.assertRaises(RuntimeError):
                MODULE.check_suite_completion(output, "suite")

    def test_failed_run_cannot_borrow_another_targets_success(self):
        output = START + "✘ Test run with 2 tests failed after 0.012 seconds.\n"
        with self.assertRaises(RuntimeError):
            MODULE.check_suite_completion(output + START + PASS, "suite")

    def test_standard_color_sequences_do_not_hide_completion(self):
        colored = START + "\x1b[32m" + PASS.rstrip("\n") + "\x1b[0m\n"
        MODULE.check_output(colored, "suite")
        MODULE.check_suite_completion(colored, "suite")


class TestCommandCompletionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="swiftty-test-command-")
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.logs = self.path / "logs"
        self.logs.mkdir()
        self.record = self.path / "arguments.json"
        fake = self.path / "swift"
        fake.write_text("""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
Path(os.environ['SWIFTTY_TEST_ARGUMENTS']).write_text(json.dumps(sys.argv[1:]))
sys.stdout.write(os.environ['SWIFTTY_TEST_STDOUT'])
sys.stdout.flush()
sys.stderr.write(os.environ.get('SWIFTTY_TEST_STDERR', ''))
sys.exit(int(os.environ['SWIFTTY_TEST_EXIT']))
""")
        fake.chmod(0o755)

    def run_command(self, output, status=0, arguments=(), stderr=""):
        environment = {
            **os.environ,
            "PATH": str(self.path) + os.pathsep + os.environ["PATH"],
            "TMPDIR": str(self.logs),
            "SWIFTTY_TEST_ARGUMENTS": str(self.record),
            "SWIFTTY_TEST_STDOUT": output,
            "SWIFTTY_TEST_STDERR": stderr,
            "SWIFTTY_TEST_EXIT": str(status),
        }
        result = subprocess.run(
            [str(ROOT / "Scripts/test.sh"), *arguments],
            cwd=self.path, env=environment, capture_output=True, text=True,
            timeout=10,
        )
        self.assertEqual(list(self.logs.iterdir()), [], "temporary log leaked")
        return result

    def test_complete_run_preserves_configuration_and_literal_arguments(self):
        for arguments in [
            [], ["-c", "release"], ["-Xswiftc", "-DSWIFTTY_INTERNAL_CHECKS"],
            ["--filter", "Test name | $(must remain literal)", "--skip-build"],
        ]:
            with self.subTest(arguments=arguments):
                result = self.run_command(START + PASS, arguments=arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(self.record.read_text()), ["test", *arguments])
                self.assertIn(PASS, result.stdout)

    def test_silent_zero_exit_rejects_an_incomplete_middle_target(self):
        output = (START + PASS) * 3 + START + "◇ Test toolbar() started.\n"
        output += (START + PASS) * 4
        result = self.run_command(output)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("8 started Swift Testing runs and 7 passing", result.stderr)

    def test_test_failure_keeps_its_exit_status_and_visible_output(self):
        result = self.run_command(START + PASS, status=17, stderr="build failed\n")
        self.assertEqual(result.returncode, 17)
        self.assertIn("build failed", result.stdout)

    def test_missing_test_run_is_rejected(self):
        result = self.run_command("Build complete!\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("0 started Swift Testing runs", result.stderr)

    def test_stderr_and_standard_colors_are_checked_with_stdout(self):
        result = self.run_command(START, stderr="\x1b[32m" + PASS.rstrip() + "\x1b[0m\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_log_capture_keeps_its_exit_status(self):
        tee = self.path / "tee"
        tee.write_text('#!/bin/sh\ncat >"$1"\nexit 19\n')
        tee.chmod(0o755)
        result = self.run_command(START + PASS)
        self.assertEqual(result.returncode, 19)

    def test_log_only_mode_preserves_control_bytes(self):
        log = self.path / "suite.log"
        for control in ["\r", "\x07", "\x1b[6n"]:
            with self.subTest(control=repr(control)):
                log.write_bytes((START + PASS + control).encode("utf-8"))
                result = subprocess.run(
                    [sys.executable, str(ROOT / "Scripts/check-test-output.py"),
                     "--suite-log", str(log)],
                    capture_output=True, text=True, timeout=10,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("contains terminal controls", result.stderr)

    def test_log_only_mode_does_not_launch_the_swift_command(self):
        log = self.path / "suite.log"
        for output, succeeds in [(START + PASS, True), (START + PASS + START, False)]:
            with self.subTest(succeeds=succeeds):
                log.write_text(output)
                result = subprocess.run(
                    [sys.executable, str(ROOT / "Scripts/check-test-output.py"),
                     "--swift", "/nonexistent/swift", "--suite-log", str(log)],
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)


if __name__ == "__main__":
    unittest.main()
