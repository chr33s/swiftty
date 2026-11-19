#!/usr/bin/env python3
"""Run the simulator roaming fixture with verified readiness and cleanup."""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

# -I excludes the script directory; add only our trusted sibling modules.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from real_ssh_commands import defer_interrupts


class FixtureError(Exception):
    pass


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def stop_host(host, grace=5):
    if host.poll() is not None:
        return
    host.terminate()
    try:
        host.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        host.kill()
        try:
            host.wait(timeout=grace)
        except subprocess.TimeoutExpired as error:
            raise FixtureError("host did not exit after SIGKILL") from error


@contextmanager
def managed_host(command, log):
    host = None
    failed = False
    try:
        # A raising signal handler must not escape between creating the child
        # and assigning the handle that cleanup needs to retire it.
        with defer_interrupts():
            host = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=log,
                                    start_new_session=True)
        yield host
    except BaseException:
        failed = True
        raise
    finally:
        # Finish bounded cleanup even if another interrupt arrives.
        previous = signal.pthread_sigmask(
            signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM}
        )
        try:
            if host is not None:
                stop_host(host)
        except Exception as error:
            print(f"Host cleanup failed: {error}", file=sys.stderr)
            if not failed:
                raise
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def wait_for_host(host, helper, config, log, timeout=10):
    deadline = time.monotonic() + timeout
    environment = {**os.environ, "SWIFTMUX_ROAMING_CONFIG": str(config)}
    while True:
        if host.poll() is not None:
            raise FixtureError(f"host exited before readiness ({host.returncode})")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise FixtureError("host readiness timed out")
        try:
            probe = subprocess.run(
                [str(helper), "status"], env=environment,
                stdout=subprocess.DEVNULL, stderr=log,
                timeout=min(1, remaining),
            )
            if (probe.returncode == 0 and host.poll() is None
                    and time.monotonic() < deadline):
                return
        except subprocess.TimeoutExpired:
            print("readiness probe timed out", file=log, flush=True)
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))


def project(root, platform):
    helpers = ["RuntimeFixture", "RuntimeSocket", "RuntimePresentationRecorder"]
    return {
        "name": "RoamingRuntime",
        "options": {"deploymentTarget": {platform: "27.0"}},
        "settings": {"base": {
            "SWIFT_VERSION": "6.0", "GENERATE_INFOPLIST_FILE": True,
            "CODE_SIGNING_ALLOWED": False,
        }},
        "packages": {"Swiftty": {"path": str(root)}},
        "targets": {"RoamingRuntimeTests": {
            "type": "bundle.unit-test", "platform": platform,
            "sources": [{"path": str(root / "Tests/SimulatorRuntime")}]
            + [{"path": str(root / f"Tests/Support/{helper}.swift")}
               for helper in helpers],
            "dependencies": [{"package": "Swiftty", "product": product}
                             for product in ["TerminalSurface", "ScreenProtocol",
                                             "SessionCore", "SwifttyCore"]],
            "settings": {"base": {
                "PRODUCT_BUNDLE_IDENTIFIER": "dev.swiftty.roaming.runtime-tests"
            }},
        }},
        "schemes": {"RoamingRuntime": {
            "build": {"targets": {"RoamingRuntimeTests": ["test"]}},
            "test": {"targets": ["RoamingRuntimeTests"]},
        }},
    }


def require_test_result(bundle, output):
    report = subprocess.check_output([
        "xcrun", "xcresulttool", "get", "test-results", "summary",
        "--schema-version", "0.4.0", "--path", str(bundle),
    ], timeout=10)
    output.write_bytes(report)
    summary = json.loads(report)
    expected = {"totalTestCount": 2, "passedTests": 2, "failedTests": 0,
                "skippedTests": 0, "expectedFailures": 0}
    if (not isinstance(summary, dict) or summary.get("result") != "Passed"
            or any(type(summary.get(key)) is not int or summary[key] != value
                   for key, value in expected.items())):
        raise FixtureError(f"result bundle does not prove the runtime test passed; see {output}")


def run(root, udid, platform, configuration="debug"):
    workspace = Path(tempfile.mkdtemp(prefix="rsts.", dir="/tmp"))
    print(f"Workspace (results and host log): {workspace}", flush=True)
    xcode_configuration = configuration.capitalize()
    (workspace / "build-configuration.json").write_text(json.dumps({
        "swiftpm": configuration, "xcode": xcode_configuration,
    }) + "\n")
    with (workspace / "build.log").open("w") as log:
        for product in ["swiftmux-agent", "swmux-launcher", "swifttyd"]:
            subprocess.run(["mise", "exec", "--", "swift", "build", "-c", configuration,
                            "--product", product],
                           cwd=root, stdout=log, stderr=log, check=True)
    binary = Path(subprocess.check_output(
        ["mise", "exec", "--", "swift", "build", "-c", configuration, "--show-bin-path"],
        cwd=root, text=True,
    ).strip())
    config = workspace / "config.json"
    config.write_text(json.dumps({
        "bindAddress": "127.0.0.1", "advertisedHost": "127.0.0.1",
        "port": 51300 + os.getpid() % 500,
        "stateDirectory": str(workspace / "state"),
    }))
    with (workspace / "host.log").open("w") as host_log:
        with managed_host([
            str(binary / "swiftmux-agent"), "--mach-service",
            f"com.chr33s.swiftty.swiftmux.test.{os.getpid()}",
            "--launcher", str(binary / "swmux-launcher"),
            "--roaming-config", str(config),
        ], host_log) as host:
            with (workspace / "readiness.log").open("w") as log:
                wait_for_host(host, binary / "swifttyd", config, log)
            spec = workspace / "project.json"
            spec.write_text(json.dumps(project(root, platform)))
            subprocess.run(["xcodegen", "generate", "--spec", str(spec)],
                           cwd=workspace, stdout=subprocess.DEVNULL, check=True)
            bundle = workspace / "result.xcresult"
            with (workspace / "xcodebuild.log").open("w") as log:
                result = subprocess.run([
                    "xcodebuild", "-scheme", "RoamingRuntime", "-destination",
                    f"platform={platform} Simulator,id={udid}",
                    "-configuration", xcode_configuration,
                    "-derivedDataPath", str(workspace / "build"),
                    "-resultBundlePath", str(bundle), "-collect-test-diagnostics", "never",
                    "-only-testing:RoamingRuntimeTests/RoamingRuntimeTests", "test",
                ], cwd=workspace, env={**os.environ,
                    "TEST_RUNNER_RST_CONTROL_SOCKET": str(workspace / "state/control.sock")},
                    stdout=log, stderr=log)
            with (workspace / "xcodebuild.log").open(errors="replace") as log:
                for line in log:
                    if re.search(r"Test Case|error:|TEST (SUCCEEDED|FAILED)|Executed", line):
                        print(line, end="")
            if result.returncode:
                raise subprocess.CalledProcessError(result.returncode, result.args)
            require_test_result(bundle, workspace / "test-summary.json")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("udid")
    parser.add_argument("platform", nargs="?", default="iOS",
                        choices=["iOS", "tvOS", "visionOS"])
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug",
                        help="build configuration for both host products and simulator tests")
    args = parser.parse_args()
    if not args.udid.strip():
        parser.error("simulator UDID must not be empty")

    def interrupt(signum, frame):
        raise Interrupted(signum)

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    try:
        status = run(Path(__file__).resolve().parent.parent, args.udid, args.platform,
                     args.configuration)
        return status if status >= 0 else 128 - status
    except Interrupted as error:
        return 128 + error.signum
    except subprocess.CalledProcessError as error:
        print(f"Fixture command failed ({error.returncode}): {error.cmd}", file=sys.stderr)
        return error.returncode if error.returncode > 0 else 128 - error.returncode
    except (OSError, ValueError, FixtureError, subprocess.TimeoutExpired) as error:
        print(f"Roaming fixture failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
