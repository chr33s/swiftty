"""Rebased installer and native publication against owned apps and fake tools."""

import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
TOOL = r'''#!/PYTHON
import json, os, plistlib, shutil, signal, subprocess, sys, time
from pathlib import Path
root = Path(os.environ['INSTALL_FIXTURE_ROOT'])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root/'calls.jsonl').open('a') as stream:
    stream.write(json.dumps([name, args])+'\n')
if name == 'package-swiftmux.sh': pass
elif name == 'swift': print(root/'repo/products')
elif name == 'launchctl':
    if args[0] == 'print' and os.environ.get('INSTALL_FIXTURE_REGISTERED_TEAM'):
        print('state = running\n"team-identifier" => "'+os.environ['INSTALL_FIXTURE_REGISTERED_TEAM']+'"')
    else: sys.exit(113)
elif name == 'pgrep': sys.exit(0)
elif name == 'codesign':
    if '-dv' in args:
        team = os.environ.get('INSTALL_FIXTURE_TEAM','not set')
        if '.Swiftty-install-' in args[-1]:
            if os.environ.get('INSTALL_FIXTURE_FAILURE') == 'metadata': sys.exit(44)
            team = os.environ.get('INSTALL_FIXTURE_STAGED_TEAM',team)
        print('TeamIdentifier='+team, file=sys.stderr)
    elif '--verify' in args:
        failure = os.environ.get('INSTALL_FIXTURE_FAILURE')
        if failure == 'verify': sys.exit(43)
        if failure == 'publish': (root/'applications with spaces').chmod(0o500)
        if failure == 'race':
            competitor = root/'applications with spaces/Swiftty.app'
            competitor.mkdir()
            (competitor/'competing').write_text('competing installation')
elif name == 'ditto':
    source, destination = map(Path, args)
    if os.environ.get('INSTALL_FIXTURE_FAILURE') == 'copy':
        destination.mkdir(parents=True, exist_ok=True)
        (destination/'partial').write_text('incomplete replacement')
        sys.exit(42)
    if os.environ.get('INSTALL_FIXTURE_FAILURE') == 'interrupt':
        destination.mkdir(parents=True, exist_ok=True)
        (destination/'partial').write_text('incomplete replacement')
        marker = root/'copy-worker.json.tmp'
        marker.write_text(json.dumps({'helper':os.getppid(),'worker':os.getpid()}))
        marker.replace(root/'copy-worker.json')
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True: time.sleep(0.1)
    shutil.copytree(source, destination, dirs_exist_ok=True)
elif name == 'sudo':
    if args[0] == 'install':
        shutil.copyfile(args[-2], args[-1])
        Path(args[-1]).chmod(0o755)
    else: sys.exit(subprocess.run(args).returncode)
elif name == 'socketfilterfw':
    if args[0] == os.environ.get('INSTALL_FIXTURE_FIREWALL_FAILURE'): sys.exit(45)
    if args[0] == '--getglobalstate':
        state = os.environ.get('INSTALL_FIXTURE_FIREWALL_ENABLED', '1')
        print('Firewall is '+('enabled' if state == '1' else 'disabled')+'. (State = '+state+')')
    elif args[0] == '--getblockall':
        print('Firewall has block all state set to '+os.environ.get('INSTALL_FIXTURE_BLOCKALL', 'disabled')+'.')
    elif args[0] == '--getappblocked':
        print('Incoming connection to '+args[1]+' is '+os.environ.get('INSTALL_FIXTURE_APP_STATE', 'permitted')+'.')
    elif args[0] not in ['--add', '--unblockapp']: raise RuntimeError(args)
elif name == 'nc': sys.exit(1)
elif name == 'swifttyd': print('ready')
elif name == 'open': pass
else: raise RuntimeError(name)
'''
APP = r'''#!/PYTHON
import json, os, sys
from pathlib import Path
root = Path(os.environ['INSTALL_FIXTURE_ROOT'])
with (root/'calls.jsonl').open('a') as stream:
    stream.write(json.dumps(['swiftty', sys.argv[1:]])+'\n')
if sys.argv[1:2] == ['--running-app']:
    print(os.environ.get('INSTALL_FIXTURE_INSTANCE_STATE', 'running'))
    sys.exit(int(os.environ.get('INSTALL_FIXTURE_APP_QUERY_STATUS', '0')))
print('enabled')
'''


@unittest.skipUnless(sys.platform == "darwin", "native macOS app publication")
class InstallTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="swiftty-install-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "repo"
        scripts = self.repo / "Scripts"
        scripts.mkdir(parents=True)
        source = (ROOT / "Scripts/install.sh").read_text()
        source = source.replace('dev_plist="$HOME/Library/LaunchAgents/$label.plist"',
                                'dev_plist=' + shlex.quote(str(self.root / "absent-dev-agent.plist")))
        # Keep roaming setup and every privileged operation inside the fixture.
        source = source.replace('helper=/usr/local/libexec/swifttyd',
                                'helper=' + shlex.quote(str(self.root / "libexec/swifttyd")))
        source = source.replace('roaming_dir="$HOME/Library/Application Support/SwiftMux/roaming"',
                                'roaming_dir=' + shlex.quote(str(self.root / "roaming")))
        source = source.replace('firewall=/usr/libexec/ApplicationFirewall/socketfilterfw',
                                'firewall=' + shlex.quote(str(self.root / "bin/socketfilterfw")))
        (scripts / "install.sh").write_text(source)
        helper = ROOT / "Scripts/install-app.py"
        if helper.exists():
            shutil.copyfile(helper, scripts / helper.name)
        self.tools = self.root / "bin"
        self.tools.mkdir()
        for path in [scripts / "package-swiftmux.sh", *(self.tools / name for name in
                     ["swift", "codesign", "launchctl", "pgrep", "ditto", "open", "sudo",
                      "socketfilterfw", "nc"])]:
            path.write_text(TOOL.replace("/PYTHON", sys.executable))
            path.chmod(0o700)
        self.built = self.repo / ".build/package/Swiftty.app"
        self.create_app(self.built, "new")
        products = self.repo / "products"
        products.mkdir()
        (products / "swifttyd").write_text(TOOL.replace("/PYTHON", sys.executable))
        self.destination = self.root / "applications with spaces"
        self.destination.mkdir()
        self.app = self.destination / "Swiftty.app"
        self.create_app(self.app, "old")
        self.environment = dict(os.environ)
        self.environment.update(INSTALL_FIXTURE_ROOT=str(self.root),
                                PATH=str(self.tools) + os.pathsep + self.environment["PATH"])
        for name in ["NOTARY_PROFILE", "NOTARY_KEY_ID"]:
            self.environment.pop(name, None)

    def create_app(self, path, marker):
        executables = path / "Contents/MacOS"
        executables.mkdir(parents=True)
        for name in ["swiftty", "swiftmux-agent", "swmux-launcher", "swmux", "swsh"]:
            file = executables / name
            file.write_text(APP.replace("/PYTHON", sys.executable))
            file.chmod(0o700)
        with (path / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "com.chr33s.swiftty",
                          "CFBundleExecutable": "swiftty"}, stream)
        (path / marker).write_text(marker)

    def install(self, *arguments, **environment):
        return subprocess.run(
            # These tests cover the Mac install; --no-devices keeps a
            # resolved team from reaching for USB-connected iPhones/iPads.
            ["/bin/sh", str(self.repo / "Scripts/install.sh"), "--identity", "-",
             "--dest", str(self.destination), "--no-devices", *arguments],
            env={**self.environment, **environment}, capture_output=True, text=True, timeout=15,
        )

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_prior_app(self):
        self.assertEqual((self.app / "old").read_text(), "old")
        self.assertFalse((self.app / "new").exists())
        self.assertFalse((self.app / "partial").exists())
        self.assertFalse(any(name == "open" or name == "swiftty" and args[:1] != ["--running-app"]
                             for name, args in self.calls()))

    def test_unrelated_same_named_process_does_not_suppress_opening_selected_app(self):
        # pgrep deliberately reports a process named swiftty. Only the exact
        # destination's application state determines whether to open this copy.
        result = self.install(INSTALL_FIXTURE_INSTANCE_STATE="stopped")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["open", ["-n", str(self.app)]], self.calls())
        self.assertNotIn("running the previous build", result.stdout)

    def test_running_destination_is_left_running_and_query_precedes_publication(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        query = calls.index(["swiftty", ["--running-app", str(self.app)]])
        copy = next(i for i, (name, _) in enumerate(calls) if name == "ditto")
        self.assertLess(query, copy)
        self.assertFalse(any(name == "open" for name, _ in calls))
        self.assertIn("running the previous build", result.stdout)

    def test_failed_or_invalid_instance_query_preserves_previous_app(self):
        for state, status in [("stopped", "1"), ("unexpected", "0")]:
            with self.subTest(state=state, status=status):
                result = self.install(INSTALL_FIXTURE_INSTANCE_STATE=state,
                                      INSTALL_FIXTURE_APP_QUERY_STATUS=status)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assert_prior_app()

    def test_copy_failure_preserves_previous_app_and_skips_registration(self):
        result = self.install(INSTALL_FIXTURE_FAILURE="copy")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_prior_app()
        self.assertEqual(list(self.destination.iterdir()), [self.app])

    def test_staged_signature_failure_preserves_previous_app(self):
        for failure in ["verify", "metadata"]:
            with self.subTest(failure=failure):
                result = self.install(INSTALL_FIXTURE_FAILURE=failure)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assert_prior_app()
                self.assertEqual(list(self.destination.iterdir()), [self.app])

    def test_successful_native_swap_preserves_open_old_file_and_registers_after_validation(self):
        with (self.app / "old").open("rb") as old:
            result = self.install()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(old.read(), b"old")
        self.assertEqual((self.app / "new").read_text(), "new")
        self.assertFalse((self.app / "old").exists())
        self.assertEqual(list(self.destination.iterdir()), [self.app])
        calls = self.calls()
        verify = next(i for i, (name, args) in enumerate(calls) if name == "codesign" and "--verify" in args)
        register = next(i for i, (name, args) in enumerate(calls)
                        if name == "swiftty" and args == ["--swiftmux-agent", "register"])
        self.assertLess(verify, register)
        self.assertTrue(any(name == "swiftty" and args == ["--swiftmux-agent", "register"]
                            for name, args in calls))
        self.assertFalse(any(name == "launchctl" and args[0] == "bootout" for name, args in calls))

    def test_first_install_and_concurrent_target_creation(self):
        shutil.rmtree(self.app)
        result = self.install(INSTALL_FIXTURE_FAILURE="race")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("File exists", result.stderr)
        self.assertEqual((self.app / "competing").read_text(), "competing installation")
        self.assertFalse((self.app / "new").exists())
        self.assertFalse(any(name == "swiftty" and args[:1] == ["--swiftmux-agent"]
                             for name, args in self.calls()))
        shutil.rmtree(self.app)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "new").read_text(), "new")
        self.assertEqual(list(self.destination.iterdir()), [self.app])

    def test_native_publication_permission_failure_preserves_previous_app(self):
        try:
            result = self.install(INSTALL_FIXTURE_FAILURE="publish")
        finally:
            self.destination.chmod(0o700)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("Permission denied", result.stderr)
        self.assert_prior_app()
        self.assertIn("cannot clean staging directory", result.stderr)
        for leftover in self.destination.iterdir():
            if leftover != self.app:
                self.assertEqual(list(leftover.iterdir()), [])

    def test_invalid_bundle_metadata_or_executables_preserve_previous_app(self):
        metadata = self.built / "Contents/Info.plist"
        original = metadata.read_bytes()
        for data in [b"not a plist", b'<?xml version="1.0"?><plist><dict>',
                     plistlib.dumps({"CFBundleIdentifier": "other.app", "CFBundleExecutable": "swiftty"})]:
            with self.subTest(data=data[:50]):
                metadata.write_bytes(data)
                result = self.install()
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assert_prior_app()
        metadata.write_bytes(original)
        executable = self.built / "Contents/MacOS/swiftmux-agent"
        executable.chmod(0o600)
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_prior_app()
        executable.unlink()
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_prior_app()

    def test_running_team_mismatch_requires_explicit_restart_and_then_reregisters(self):
        setting = {"INSTALL_FIXTURE_REGISTERED_TEAM": "OLDTEAM123", "INSTALL_FIXTURE_TEAM": "NEWTEAM123"}
        result = self.install(**setting)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_prior_app()
        self.assertFalse(any(name == "ditto" for name, _ in self.calls()))
        result = self.install("--restart-agent", **setting)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertTrue(any(name == "swiftty" and args == ["--swiftmux-agent", "unregister"]
                            for name, args in calls))
        self.assertTrue(any(name == "launchctl" and args[0] == "bootout" for name, args in calls))

    def test_running_matching_team_is_not_unregistered_or_stopped(self):
        result = self.install(INSTALL_FIXTURE_REGISTERED_TEAM="SAME123456",
                              INSTALL_FIXTURE_TEAM="SAME123456")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "new").read_text(), "new")
        self.assertFalse(any(name == "swiftty" and "unregister" in args
                             or name == "launchctl" and args[0] == "bootout"
                             for name, args in self.calls()))

    def test_staged_team_change_cannot_invalidate_the_restart_decision(self):
        result = self.install(INSTALL_FIXTURE_REGISTERED_TEAM="SAME123456",
                              INSTALL_FIXTURE_TEAM="SAME123456",
                              INSTALL_FIXTURE_STAGED_TEAM="DIFF123456")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assert_prior_app()
        self.assertEqual(list(self.destination.iterdir()), [self.app])

    def test_relative_destination_directory_alias_keeps_the_selected_location(self):
        alias = self.repo / "alias directory"
        alias.symlink_to(self.destination, target_is_directory=True)
        result = self.install("--dest", alias.name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "new").read_text(), "new")
        self.assertEqual(list(self.destination.iterdir()), [self.app])

    def test_replacing_a_destination_symlink_keeps_its_external_target(self):
        previous = self.root / "previous.app"
        self.app.rename(previous)
        self.app.symlink_to(previous, target_is_directory=True)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.app.is_symlink())
        self.assertEqual((self.app / "new").read_text(), "new")
        self.assertEqual((previous / "old").read_text(), "old")
        self.assertEqual(list(self.destination.iterdir()), [self.app])

    def test_empty_or_option_like_destinations_fail_before_commands(self):
        for value in ["", "-", "-directory"]:
            with self.subTest(value=value):
                result = self.install("--dest", value)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertEqual(self.calls(), [])
                self.assert_prior_app()

    def test_firewall_option_requires_roaming_before_any_commands(self):
        result = self.install("--configure-firewall")
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertIn("--configure-firewall requires --roaming", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_missing_firewall_tool_fails_before_installation(self):
        (self.tools / "socketfilterfw").unlink()
        result = self.install("--roaming", "--configure-firewall")
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("firewall tool unavailable", result.stderr)
        self.assertEqual(self.calls(), [])
        self.assert_prior_app()

    def test_roaming_leaves_firewall_untouched_by_default(self):
        result = self.install("--roaming", "--host", "test.local")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(name == "socketfilterfw" for name, _ in self.calls()))
        self.assertIn("nothing is changed", result.stdout)
        self.assertIn("--roaming --configure-firewall", result.stdout)

    def test_firewall_exception_targets_installed_agent_and_is_reapplied(self):
        # The firewall always receives the installed executable's absolute path,
        # including when --dest names a relative directory with spaces.
        alias = self.repo / "alias directory"
        alias.symlink_to(self.destination, target_is_directory=True)
        for _ in range(2):
            result = self.install("--roaming", "--host", "test.local", "--configure-firewall",
                                  "--dest", alias.name)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("macOS firewall exception configured for SwiftMux", result.stdout)
            self.assertNotIn("nothing is changed", result.stdout)
            self.assertIn("remote reachability is not verified", result.stdout)
        agent = str((self.app / "Contents/MacOS/swiftmux-agent").resolve())
        expected = [["--getglobalstate"], ["--getblockall"], ["--add", agent],
                    ["--unblockapp", agent], ["--getappblocked", agent]]
        calls = self.calls()
        self.assertEqual([args for name, args in calls if name == "socketfilterfw"], expected * 2)
        privileged = [args for name, args in calls
                      if name == "sudo" and Path(args[0]).name == "socketfilterfw"]
        tool = str(self.tools / "socketfilterfw")
        self.assertEqual(privileged, [[tool, "--add", agent], [tool, "--unblockapp", agent]] * 2)
        verify = next(i for i, (name, args) in enumerate(calls)
                      if name == "codesign" and "--verify" in args)
        configure = next(i for i, (name, args) in enumerate(calls)
                         if name == "socketfilterfw" and "--add" in args)
        self.assertLess(verify, configure)

    def test_firewall_reports_disabled_and_block_all_without_changing_global_policy(self):
        result = self.install("--roaming", "--host", "test.local", "--configure-firewall",
                              INSTALL_FIXTURE_FIREWALL_ENABLED="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("macOS firewall is off", result.stdout)
        result = self.install("--roaming", "--configure-firewall", INSTALL_FIXTURE_BLOCKALL="enabled")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Block all incoming connections overrides the SwiftMux exception", result.stdout)
        self.assertFalse(any(name == "socketfilterfw" and args[0].startswith("--set")
                             for name, args in self.calls()))

    def test_firewall_command_failures_are_not_reported_as_success(self):
        for operation in ["--getglobalstate", "--getblockall", "--add", "--unblockapp", "--getappblocked"]:
            with self.subTest(operation=operation):
                (self.root / "calls.jsonl").unlink(missing_ok=True)
                result = self.install("--roaming", "--host", "test.local", "--configure-firewall",
                                      INSTALL_FIXTURE_FIREWALL_FAILURE=operation)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn("install.sh:", result.stderr)
                self.assertNotIn("macOS firewall exception configured", result.stdout)
                firewall_calls = [args for name, args in self.calls() if name == "socketfilterfw"]
                self.assertEqual(firewall_calls[-1][0], operation)

    def test_firewall_denied_or_unrecognized_exception_is_not_reported_as_success(self):
        for state in ["blocked", "unknown"]:
            with self.subTest(state=state):
                result = self.install("--roaming", "--host", "test.local", "--configure-firewall",
                                      INSTALL_FIXTURE_APP_STATE=state)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn("exception was not verified", result.stderr)
                self.assertNotIn("macOS firewall exception configured", result.stdout)

    def test_repeated_interruption_joins_the_owned_copy_worker_and_preserves_previous_app(self):
        with tempfile.TemporaryFile() as output:
            process = subprocess.Popen(
                ["/usr/bin/python3", "-I", str(self.repo / "Scripts/install-app.py"),
                 str(self.built), str(self.app), ""],
                env={**self.environment, "INSTALL_FIXTURE_FAILURE": "interrupt"},
                stdout=output, stderr=output,
            )
            self.addCleanup(self.finish_helper, process)
            marker = self.root / "copy-worker.json"
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(marker.exists())
            owned = json.loads(marker.read_text())
            self.assertEqual(owned["helper"], process.pid)
            process.send_signal(signal.SIGTERM)
            for _ in range(20):
                if process.poll() is not None:
                    break
                try:
                    process.send_signal(signal.SIGTERM)
                except ProcessLookupError:
                    break
                time.sleep(0.005)
            self.assertEqual(process.wait(timeout=5), 128 + signal.SIGTERM)
            with self.assertRaises(ProcessLookupError):
                os.kill(owned["worker"], 0)
        self.assert_prior_app()
        self.assertEqual(list(self.destination.iterdir()), [self.app])

    def finish_helper(self, process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    def sign_owned_app(self):
        resources = self.built / "Contents/Resources"
        resources.mkdir()
        (self.built / "new").rename(resources / "new")
        executable = self.root / "native-main"
        compiled = subprocess.run(["/usr/bin/clang", "-x", "c", "-o", str(executable), "-"],
                                  input="int main(void) { return 0; }\n", text=True,
                                  capture_output=True, timeout=20)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        for name in ["swiftty", "swiftmux-agent", "swmux-launcher", "swmux", "swsh"]:
            target = self.built / "Contents/MacOS" / name
            shutil.copyfile(executable, target)
            target.chmod(0o700)
        for name in ["swiftmux-agent", "swmux-launcher", "swmux", "swsh"]:
            target = self.built / "Contents/MacOS" / name
            signed = subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-",
                                     "--timestamp=none", str(target)], capture_output=True,
                                    text=True, timeout=10)
            self.assertEqual(signed.returncode, 0, signed.stderr)
        signed = subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-",
                                 "--timestamp=none", str(self.built)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(signed.returncode, 0, signed.stderr)

    def run_native_helper(self):
        return subprocess.run(
            ["/usr/bin/python3", "-I", str(ROOT / "Scripts/install-app.py"),
             str(self.built), str(self.app), ""],
            env={**self.environment, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
            capture_output=True, text=True, timeout=15,
        )

    def test_real_ditto_codesign_and_native_swap_publish_an_owned_ad_hoc_app(self):
        self.sign_owned_app()
        result = self.run_native_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "Contents/Resources/new").read_text(), "new")
        self.assertFalse((self.app / "old").exists())
        verified = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(self.app)],
                                  capture_output=True, text=True, timeout=10)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertEqual(list(self.destination.iterdir()), [self.app])

    def test_real_signature_verification_rejects_a_tampered_owned_app_without_replacement(self):
        self.sign_owned_app()
        (self.built / "Contents/Resources/new").write_text("changed after signing")
        result = self.run_native_helper()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("cannot replace app", result.stderr)
        self.assert_prior_app()
        self.assertEqual(list(self.destination.iterdir()), [self.app])


if __name__ == "__main__":
    unittest.main()
