"""Exercise the native test host's ABI, run-loop, and completion behavior."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = r'''
import AppKit
import CoreFoundation
import Darwin
import Foundation

typealias EntryPoint = @convention(thin) @Sendable (
  UnsafeRawBufferPointer?,
  @escaping @Sendable (UnsafeRawBufferPointer) -> Void
) async throws -> Bool

private func emit(_ object: [String: Any], to handler: (UnsafeRawBufferPointer) -> Void) {
  let bytes = try! JSONSerialization.data(withJSONObject: object)
  bytes.withUnsafeBytes { handler($0) }
}

private func entry(
  _ configuration: UnsafeRawBufferPointer?,
  _ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void
) async throws -> Bool {
  guard let configuration,
        let json = try JSONSerialization.jsonObject(with: Data(configuration)) as? [String: Any],
        json["eventStreamVersion"] as? Int == 0,
        json["parallel"] as? Bool == false else {
    throw NSError(domain: "missing schema configuration", code: 1)
  }
  let scenario = ProcessInfo.processInfo.environment["SWIFTTY_HOST_SCENARIO"]!
  if scenario == "parentAudit" { print("◇ Test run started.") }
  func event(_ kind: String, id: String? = nil) {
    var payload: [String: Any] = ["kind": kind]
    if let id { payload["testID"] = id }
    emit(["version": 0, "kind": "event", "payload": payload], to: handler)
  }
  if scenario != "empty" {
    emit(["version": 0, "kind": "test", "payload": ["kind": "function"]], to: handler)
  }
  event("runStarted")
  if scenario != "empty" { event("testStarted", id: "fixture") }
  // Both stops happen while the async entry point is still suspended.
  for delay in [0.01, 0.02] {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      print("FIXTURE_LOOP_STOP")
      CFRunLoopStop(CFRunLoopGetMain())
    }
  }
  if scenario == "applicationStopped" {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
      let app = NSApplication.shared
      app.stop(nil)
      if let event = NSEvent.otherEvent(
        with: .applicationDefined, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
      ) {
        app.postEvent(event, atStart: true)
      }
    }
  }
  try await Task.sleep(for: .milliseconds(60))
  if scenario == "applicationLoop" {
    let running = await MainActor.run { NSApplication.shared.isRunning }
    print("FIXTURE_APPLICATION_RUNNING=\(running)")
    if !running { return false }
  }
  if scenario == "throws" { throw NSError(domain: "fixture", code: 1) }
  if scenario != "empty", scenario != "unfinished" {
    event("testEnded", id: "fixture")
  }
  if scenario == "duplicate" { event("testEnded", id: "fixture") }
  if scenario != "incomplete" { event("runEnded") }
  print("FIXTURE_ENTRY_FINISHED")
  if scenario == "parentAudit" {
    print("✔ Test run with 1 test in 1 suite passed after 0.001 seconds.")
  }
  return scenario != "failure"
}

@_cdecl("swt_abiv0_getEntryPoint")
public func getter() -> UnsafeRawPointer {
  let environment = ProcessInfo.processInfo.environment
  if environment["SWIFTTY_HOST_SCENARIO"] == "parentAudit",
    environment["SWIFTTY_TEST_BUNDLE"]?.hasSuffix("/OneTests") == true
  { exit(0) }
  let function: EntryPoint = { configuration, handler in
    try await entry(configuration, handler)
  }
  return unsafeBitCast(function, to: UnsafeRawPointer.self)
}
'''
DECOY = r'''
import Darwin

@_cdecl("swt_abiv0_getEntryPoint")
public func getter() -> UnsafeRawPointer {
  print("DECOY_ENTRY_POINT")
  exit(3)
}
'''


@unittest.skipUnless(sys.platform == "darwin", "native macOS ABI fixture")
class NativeTestHostTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="swiftty-native-host-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.path = Path(cls.directory.name)
        cls.host = cls.path / "host"
        cls.library = cls.path / "fixture.dylib"
        fixture = cls.path / "fixture.swift"
        fixture.write_text(FIXTURE)
        # A second Swift Testing copy that exports the same ABI entry point,
        # linked ahead of the real one, as XCTest does for swift.org bundles.
        decoy = cls.path / "decoy.swift"
        decoy.write_text(DECOY)
        cls.decoy = cls.path / "decoy.dylib"
        cls.two_copies = cls.path / "two-copies.dylib"
        empty = cls.path / "empty.swift"
        empty.write_text("")
        for command in [
            ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(ROOT / "Scripts/SwiftTestingHost.swift"),
             "-o", str(cls.host)],
            ["xcrun", "swiftc", "-swift-version", "6", "-emit-library", str(fixture), "-o", str(cls.library)],
            ["xcrun", "swiftc", "-swift-version", "6", "-emit-library", str(decoy), "-o", str(cls.decoy)],
            ["xcrun", "swiftc", "-swift-version", "6", "-emit-library", str(empty), "-o", str(cls.two_copies),
             "-Xlinker", str(cls.decoy), "-Xlinker", str(cls.library)],
        ]:
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if result.returncode != 0:
                raise RuntimeError(result.stderr)

    def run_host(self, scenario, library=None, testing_library=None):
        environment = {**os.environ, "SWIFTTY_TEST_BUNDLE": str(library or self.library),
                       "SWIFTTY_HOST_SCENARIO": scenario}
        environment.pop("SWIFTTY_TESTING_LIBRARY", None)
        if testing_library is not None:
            environment["SWIFTTY_TESTING_LIBRARY"] = testing_library
        return subprocess.run(
            [str(self.host)], env=environment, capture_output=True, text=True, timeout=10,
        )

    def test_entry_point_comes_from_the_bundles_testing_library(self):
        unselected = self.run_host("complete", self.two_copies)
        self.assertIn("DECOY_ENTRY_POINT", unselected.stdout)
        result = self.run_host("complete", self.two_copies, str(self.library))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("DECOY_ENTRY_POINT", result.stdout)
        self.assertIn("FIXTURE_ENTRY_FINISHED", result.stdout)

    def test_rpath_testing_library_matches_the_loaded_image_path(self):
        result = self.run_host("complete", self.two_copies, "@rpath/fixture.dylib")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FIXTURE_ENTRY_FINISHED", result.stdout)

    def test_unloaded_testing_library_does_not_fall_back_to_another_copy(self):
        result = self.run_host("complete", self.two_copies, "@rpath/libTesting.dylib")
        self.assertEqual(result.returncode, 1)
        self.assertIn("@rpath/libTesting.dylib is not loaded", result.stderr)
        self.assertNotIn("DECOY_ENTRY_POINT", result.stdout)

    def test_complete_run_survives_two_main_loop_stops(self):
        result = self.run_host("complete")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("FIXTURE_ENTRY_FINISHED", result.stdout)
        self.assertEqual(result.stdout.count("FIXTURE_LOOP_STOP"), 2)

    def test_native_tests_run_inside_the_appkit_application_loop(self):
        result = self.run_host("applicationLoop")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FIXTURE_APPLICATION_RUNNING=true", result.stdout)

    def test_stopping_the_application_cannot_report_an_incomplete_run_as_success(self):
        result = self.run_host("applicationStopped")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("loop ended before completed test execution", result.stderr)
        self.assertNotIn("FIXTURE_ENTRY_FINISHED", result.stdout)

    def test_incomplete_or_unfinished_run_cannot_report_success(self):
        for scenario in ["incomplete", "unfinished", "duplicate", "empty"]:
            with self.subTest(scenario=scenario):
                result = self.run_host(scenario)
                self.assertEqual(result.returncode, 1)
                self.assertIn("did not report a complete nonempty run", result.stderr)

    def test_completed_failing_tests_preserve_failure(self):
        result = self.run_host("failure")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FIXTURE_ENTRY_FINISHED", result.stdout)
        self.assertNotIn("did not report", result.stderr)

    def test_entry_failure_does_not_hang(self):
        result = self.run_host("throws")
        self.assertEqual(result.returncode, 1)
        self.assertIn("could not start", result.stderr)

    def test_unloadable_bundle_does_not_report_success(self):
        result = self.run_host("complete", self.path / "missing.dylib")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Unable to load", result.stderr)

    def test_parent_rejects_a_native_zero_exit_before_the_abi_entry_point(self):
        fixture = self.path / "parent-command"
        fixture.mkdir()
        products = fixture / "products"
        logs = fixture / "logs"
        logs.mkdir()
        for name in ["OneTests", "TwoTests"]:
            bundle = products / f"{name}.xctest/Contents/MacOS/{name}"
            bundle.parent.mkdir(parents=True)
            shutil.copyfile(self.library, bundle)
        compiler = fixture / "swiftc"
        compiler.write_text("""#!/usr/bin/env python3
import json, shutil, sys
if '-print-target-info' in sys.argv:
    print(json.dumps({'paths': {'runtimeLibraryPaths': []}}))
else:
    shutil.copyfile(""" + repr(str(self.host)) + """, sys.argv[sys.argv.index('-o') + 1])
    import os
    os.chmod(sys.argv[sys.argv.index('-o') + 1], 0o700)
""")
        compiler.chmod(0o700)
        swift = fixture / "swift"
        swift.write_text("""#!/usr/bin/env python3
import json, sys
if '--show-bin-path' in sys.argv:
    print(""" + repr(str(products)) + """)
elif sys.argv[1:3] == ['package', 'dump-package']:
    print(json.dumps({'targets': [
        {'name': 'OneTests', 'type': 'test'}, {'name': 'TwoTests', 'type': 'test'}]}))
""")
        swift.chmod(0o700)
        result = subprocess.run(
            [str(ROOT / "Scripts/test-native.sh"), "--skip-build"],
            env={**os.environ, "PATH": str(fixture) + os.pathsep + os.environ["PATH"],
                 "TMPDIR": str(logs), "SWIFTTY_HOST_SCENARIO": "parentAudit"},
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Incomplete test bundle: OneTests", result.stdout)
        self.assertEqual(result.stdout.count("Test run started."), 1)
        self.assertIn("FIXTURE_ENTRY_FINISHED", result.stdout)
        self.assertEqual(list(logs.iterdir()), [], "temporary workspace leaked")


FAKE_HOST = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
target = Path(os.environ['SWIFTTY_TEST_BUNDLE']).name
with Path(os.environ['SWIFTTY_NATIVE_HOST_RECORD']).open('a') as record:
    record.write(json.dumps(target) + '\\n')
with Path(os.environ['SWIFTTY_NATIVE_LAUNCHER_RECORD']).open('a') as record:
    record.write(json.dumps(os.environ.get('SWMUX_LAUNCHER')) + '\\n')
scenario = os.environ.get('SWIFTTY_NATIVE_SCENARIO', '')
selected = os.environ.get('SWIFTTY_NATIVE_SELECTED', 'OneTests')
if target == selected and scenario == 'silent':
    sys.exit(0)
if target == selected and scenario == 'summary-only':
    print('✔ Test run with 1 test in 1 suite passed after 0.001 seconds.')
    sys.exit(0)
if scenario == 'colored':
    print('\\x1b[32m◇ Test run started.\\x1b[0m')
    print('\\x1b[32m✔ Test run with 1 test in 1 suite passed after 0.001 seconds.\\x1b[0m')
    sys.exit(0)
print('◇ Test run started.')
if target == selected and scenario in ['unfinished', 'borrowed-completion']:
    sys.exit(0)
print('✔ Test run with 1 test in 1 suite passed after 0.001 seconds.')
if scenario == 'borrowed-completion':
    print('✔ Test run with 1 test in 1 suite passed after 0.001 seconds.')
if target == selected and scenario == 'control':
    sys.stdout.write('owned raw carriage return\\r')
if os.environ.get('SWIFTTY_NATIVE_FAILURE') == '1':
    sys.exit(1)
"""


@unittest.skipUnless(sys.platform == "darwin", "native macOS test command")
class NativeTestCommandTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="swiftty-native-command-")
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.bin = self.path / "products"
        self.logs = self.path / "logs"
        self.logs.mkdir()
        self.record = self.path / "commands.jsonl"
        self.host_record = self.path / "hosts.jsonl"
        self.launcher_record = self.path / "launchers.jsonl"
        for name in ["OneTests", "TwoTests"]:
            bundle = self.bin / f"{name}.xctest/Contents/MacOS/{name}"
            bundle.parent.mkdir(parents=True)
            bundle.touch()
        fake = self.path / "swift"
        fake.write_text("""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
with Path(os.environ['SWIFTTY_NATIVE_RECORD']).open('a') as record:
    record.write(json.dumps(sys.argv[1:]) + '\\n')
if '--show-bin-path' in sys.argv:
    print(os.environ['SWIFTTY_NATIVE_PRODUCTS'])
elif sys.argv[1:3] == ['package', 'dump-package']:
    print(json.dumps({'targets': [
      {'name': 'Production', 'type': 'regular'},
      {'name': 'OneTests', 'type': 'test'}, {'name': 'TwoTests', 'type': 'test'}]}))
""")
        fake.chmod(0o755)
        compiler = self.path / "swiftc"
        compiler.write_text("""#!/usr/bin/env python3
import json
from pathlib import Path
import sys
if '-print-target-info' in sys.argv:
    print(json.dumps({'paths': {'runtimeLibraryPaths': []}}))
else:
    output = Path(sys.argv[sys.argv.index('-o') + 1])
    output.write_text(""" + repr(FAKE_HOST) + """ )
    output.chmod(0o755)
""")
        compiler.chmod(0o755)

    def run_command(self, arguments=(), failure=False, scenario="", selected="OneTests", launcher=None):
        environment = dict(os.environ)
        environment.pop("SWMUX_LAUNCHER", None)
        if launcher is not None:
            environment["SWMUX_LAUNCHER"] = launcher
        result = subprocess.run(
            [str(ROOT / "Scripts/test-native.sh"), *arguments],
            cwd=self.path,
            env={**environment, "PATH": str(self.path) + os.pathsep + os.environ["PATH"],
                 "TMPDIR": str(self.logs), "SWIFTTY_NATIVE_RECORD": str(self.record),
                 "SWIFTTY_NATIVE_PRODUCTS": str(self.bin),
                 "SWIFTTY_NATIVE_HOST_RECORD": str(self.host_record),
                 "SWIFTTY_NATIVE_LAUNCHER_RECORD": str(self.launcher_record),
                 "SWIFTTY_NATIVE_SCENARIO": scenario, "SWIFTTY_NATIVE_SELECTED": selected,
                 "SWIFTTY_NATIVE_FAILURE": "1" if failure else "0"},
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(list(self.logs.iterdir()), [], "temporary workspace leaked")
        return result

    def commands(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()]

    def hosts(self):
        if not self.host_record.exists():
            return []
        return [json.loads(line) for line in self.host_record.read_text().splitlines()]

    def launchers(self):
        return [json.loads(line) for line in self.launcher_record.read_text().splitlines()]

    def test_selected_products_launcher_is_exported_for_each_configuration(self):
        for directory, arguments in [
            ("Debug", []), ("Release", ["-c", "release"]),
            ("Custom build products", ["--scratch-path", str(self.path / "scratch")]),
        ]:
            with self.subTest(directory=directory):
                products = self.path / directory
                self.bin.rename(products)
                self.bin = products
                self.launcher_record.unlink(missing_ok=True)
                result = self.run_command(["--skip-build", *arguments])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.launchers(), [str(self.bin / "swmux-launcher")] * 2)

    def test_explicit_launcher_override_is_preserved(self):
        override = str(self.path / "explicit launcher")
        result = self.run_command(["--skip-build", "-c", "release"], launcher=override)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.launchers(), [override] * 2)

    def test_empty_explicit_launcher_is_not_replaced(self):
        result = self.run_command(["--skip-build"], launcher="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.launchers(), [""] * 2)

    def test_default_full_run_builds_and_runs_every_manifest_test_target(self):
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("Test run started."), 2)
        self.assertIn(["build", "--build-tests", "-Xswiftc", "-enable-testing"], self.commands())

    def test_release_build_enables_testable_imports(self):
        result = self.run_command(["-c", "release"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            ["build", "--build-tests", "-Xswiftc", "-enable-testing", "-c", "release"],
            self.commands(),
        )

    def test_skip_build_and_configuration_arguments_are_forwarded(self):
        for arguments in [["-c", "release"], ["-Xswiftc", "-DSWIFTTY_INTERNAL_CHECKS"]]:
            with self.subTest(arguments=arguments):
                self.record.unlink(missing_ok=True)
                result = self.run_command(["--skip-build", *arguments])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(["build", "--show-bin-path", *arguments], self.commands())
                self.assertIn(["package", "dump-package", *arguments], self.commands())
                self.assertFalse(any('--build-tests' in command for command in self.commands()))

    def test_missing_declared_bundle_fails_even_after_another_completed_target(self):
        (self.bin / "TwoTests.xctest/Contents/MacOS/TwoTests").unlink()
        result = self.run_command(["--skip-build"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("Missing test bundle: TwoTests", result.stdout)

    def test_failed_target_is_not_hidden_by_completed_output(self):
        result = self.run_command(["--skip-build"], failure=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.count("Test run started."), 2)

    def test_silent_zero_exit_target_fails_independently_of_its_position(self):
        for selected in ["OneTests", "TwoTests"]:
            with self.subTest(selected=selected):
                self.host_record.unlink(missing_ok=True)
                result = self.run_command(["--skip-build"], scenario="silent", selected=selected)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(f"Incomplete test bundle: {selected}", result.stdout)
                self.assertEqual(self.hosts(), ["OneTests", "TwoTests"])

    def test_completion_from_another_bundle_cannot_balance_an_unfinished_run(self):
        result = self.run_command(["--skip-build"], scenario="borrowed-completion")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Incomplete test bundle: OneTests", result.stdout)
        self.assertIn("Incomplete test bundle: TwoTests", result.stdout)
        self.assertEqual(self.hosts(), ["OneTests", "TwoTests"])

    def test_missing_first_bundle_does_not_prevent_running_later_targets(self):
        (self.bin / "OneTests.xctest/Contents/MacOS/OneTests").unlink()
        result = self.run_command(["--skip-build"])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Missing test bundle: OneTests", result.stdout)
        self.assertEqual(self.hosts(), ["TwoTests"])

    def test_unfinished_zero_exit_target_still_runs_later_targets_and_fails(self):
        result = self.run_command(["--skip-build"], scenario="unfinished")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Incomplete test bundle: OneTests", result.stdout)
        self.assertEqual(self.hosts(), ["OneTests", "TwoTests"])

    def test_completion_without_a_start_cannot_report_a_complete_bundle(self):
        result = self.run_command(["--skip-build"], scenario="summary-only")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("completion without a run start", result.stdout)
        self.assertIn("Incomplete test bundle: OneTests", result.stdout)
        self.assertEqual(self.hosts(), ["OneTests", "TwoTests"])

    def test_raw_controls_are_checked_per_bundle_without_stopping_later_targets(self):
        result = self.run_command(["--skip-build"], scenario="control")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("terminal controls: [13]", result.stdout)
        self.assertIn("Incomplete test bundle: OneTests", result.stdout)
        self.assertEqual(self.hosts(), ["OneTests", "TwoTests"])

    def test_allowed_color_sequences_preserve_each_bundles_completion(self):
        result = self.run_command(["--skip-build"], scenario="colored")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.hosts(), ["OneTests", "TwoTests"])


if __name__ == "__main__":
    unittest.main()
