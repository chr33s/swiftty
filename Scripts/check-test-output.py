#!/usr/bin/env python3
"""Verify suite output and real passing/failing Swift Testing diagnostics."""

import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
# Swift Testing can intentionally color its output. These SGR sequences do
# not include character-set selection, OSC, cursor movement, or fixture data.
SGR = re.compile(r"\x1b\[[0-9;]*m")


def check_output(output: str, name: str) -> None:
    plain = SGR.sub("", output)
    controls = sorted({
        ord(c) for c in plain
        if (ord(c) < 0x20 and c not in "\n\t") or 0x7F <= ord(c) <= 0x9F
    })
    if controls:
        raise RuntimeError(f"{name} contains terminal controls: {controls}")


def run(command: list[str], directory: Path, environment: dict[str, str],
        log: Path) -> subprocess.CompletedProcess[str]:
    capture = subprocess.run(command, cwd=directory, env=environment,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    # Decode explicitly: text-mode subprocesses turn CR into LF, hiding
    # carriage-return fixtures from the control-byte check.
    result = subprocess.CompletedProcess(capture.args, capture.returncode,
                                         capture.stdout.decode("utf-8"))
    log.write_text(result.stdout, encoding="utf-8")
    check_output(result.stdout, log.name)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    environment.pop("SWIFTTY_OUTPUT_PROBE_FAIL", None)

    suite = run([args.swift, "test", "--skip-build"], ROOT, environment,
                output / "suite.log")
    if suite.returncode != 0 or "Test run with" not in suite.stdout:
        raise RuntimeError("the built test suite did not pass")

    with tempfile.TemporaryDirectory(prefix="swiftty-output-probe-") as temporary:
        package = Path(temporary)
        sources = package / "Sources"
        sources.mkdir()
        (sources / "TestSupport").symlink_to(ROOT / "Tests" / "Support")
        tests = package / "Tests"
        tests.mkdir()
        (package / "Package.swift").write_text("""
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "OutputProbe",
    targets: [
        .target(name: "TestSupport"),
        .testTarget(name: "OutputProbeTests", dependencies: ["TestSupport"]),
    ]
)
""")
        (tests / "OutputProbeTests.swift").write_text(r"""
import Foundation
import Testing
import TestSupport

let controls = String(String.UnicodeScalarView(
    (Array(0 ... 0x1F) + Array(0x7F ... 0x9F)).map { Unicode.Scalar(UInt32($0))! }
))
let text = "\u{1B}(0q\u{1B}]52;c;YQ==\u{07}" + controls

struct OutputProbeTests {
    @Test(arguments: [TestFixture(text)])
    func textFixtures(_ fixture: TestFixture<String>) {
        #expect(fixture.value.utf8.first == 0x1B)
    }

    @Test(arguments: [TestFixture((text, [text], (text, true)))])
    func nestedFixtures(_ fixture: TestFixture<(String, [String], (String, Bool))>) {
        #expect(fixture.value.1.first?.utf8.first == 0x1B)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTTY_OUTPUT_PROBE_FAIL"] == "1"),
          arguments: [TestFixture(text)])
    func deliberateFailure(_ fixture: TestFixture<String>) {
        #expect(fixture == TestFixture("deliberately different"),
                Comment(rawValue: escapedTestText("fixture=" + fixture.value)))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTTY_OUTPUT_PROBE_FAIL"] == "1"),
          arguments: [TestFixture(text)])
    func deliberateArrayFailure(_ fixture: TestFixture<String>) {
        #expect(TestFixture([fixture.value]) == TestFixture(["deliberately different"]))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTTY_OUTPUT_PROBE_FAIL"] == "1"),
          arguments: [TestFixture(text)])
    func deliberateBooleanFailure(_ fixture: TestFixture<String>) {
        #expect(TestFixture(fixture.value.hasPrefix("deliberately different")) == TestFixture(true))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTTY_OUTPUT_PROBE_FAIL"] == "1"),
          arguments: [TestFixture(text)])
    func deliberateRequiredValueFailure(_ fixture: TestFixture<String>) throws {
        func missing(_ raw: String) -> String? { nil }
        _ = try #require(TestFixture(missing(fixture.value)).value)
    }

}
""")
        passing = run([args.swift, "test"], package, environment,
                      output / "passing.log")
        if passing.returncode != 0 or "Test run with" not in passing.stdout:
            raise RuntimeError("passing fixture probe did not pass")
        failing_environment = {**environment, "SWIFTTY_OUTPUT_PROBE_FAIL": "1"}
        failing = run([args.swift, "test", "--skip-build"], package,
                      failing_environment, output / "failing.log")
        if failing.returncode == 0 or "Expectation failed" not in failing.stdout:
            raise RuntimeError("failing fixture probe did not report the intended failure")
        for name in ["deliberateFailure", "deliberateArrayFailure",
                     "deliberateBooleanFailure", "deliberateRequiredValueFailure"]:
            if not re.search(r"Test " + name + r".*recorded an issue", failing.stdout):
                raise RuntimeError(f"{name} did not report its intended failure")
        for name, result in [("passing", passing), ("failing", failing)]:
            if "\\u{1B}(0q" not in result.stdout:
                raise RuntimeError(f"{name} probe did not report the escaped fixture")
    print("Suite, passing fixtures, nested tuples, and deliberate failure output are safe.")


if __name__ == "__main__":
    main()
