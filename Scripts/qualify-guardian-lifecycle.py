#!/usr/bin/env python3
"""Signed independent-helper proof for spec.durability.md A0.

Default mode uses the existing mux as a real-PTY fixture. --worker-transport
qualifies raw supervised transport; --workspace-worker uses the actual worker,
terminal engine and gateway control client. None qualifies the installed product
gateway facade, immutable updater or migration. Owns unique probe registrations;
never registers, unregisters or terminates the installed SwiftMux service.
Artifacts and structured evidence remain in the printed temporary directory.
--worker-builds additionally qualifies signed registry publication, selection,
version-specific resources and live pins using two build IDs of the same code.
--guardian-daemon registers the exact guardian executable and verifies its
configured gateway signing identity, restart behavior and explicit End.
--gateway-daemon uses both exact daemons and a separate signed native frontend.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import uuid


def run(*args, timeout=30):
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}): {result.stderr}\n{result.stdout[-12000:]}")
    return result.stdout.strip()


def bundle(path, label, build, binary, launcher, identity, mode="serve", probe_root=None,
           worker=None, guardian_service=None, workspace=None, guardian_daemon=None,
           gateway_identifier=None, gateway_daemon=None, cli=None):
    contents = path / "Contents"
    macos = contents / "MacOS"
    agents = contents / "Library" / "LaunchAgents"
    macos.mkdir(parents=True)
    agents.mkdir(parents=True)
    executables = [(binary, "probe"), (launcher, "swmux-launcher")]
    if worker:
        executables.append((worker, "swiftmux-worker"))
    if guardian_daemon:
        executables.append((guardian_daemon, "swiftmux-guardian"))
    if gateway_daemon:
        executables.append((gateway_daemon, "swiftmux-gateway"))
    if cli:
        executables.append((cli, "swmux"))
    for source, name in executables:
        shutil.copy2(source, macos / name)
        run("/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp",
            "--sign", identity, "--identifier", label + "." + name, str(macos / name))
    with (contents / "Info.plist").open("wb") as file:
        plistlib.dump({
            "CFBundleIdentifier": label + ".app", "CFBundleName": "SwiftMux Lifecycle Probe",
            "CFBundleExecutable": "probe", "CFBundlePackageType": "APPL",
            "CFBundleVersion": str(build), "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "27.0", "LSUIElement": True,
            "ProbeService": label,
            **({"ProbeEvidence": str(probe_root)} if probe_root else {}),
            **({"ProbeGuardian": guardian_service} if guardian_service else {}),
            **({"ProbeWorkspace": workspace} if workspace else {}),
            **({"ProbeGatewayIdentifier": gateway_identifier} if gateway_identifier else {}),
        }, file)
    if gateway_daemon:
        resources = contents / "Resources"
        resources.mkdir(exist_ok=True)
        (resources / "gateway-build.json").write_text(json.dumps({
            "schema": 1, "build": str(build), "guardianProtocol": 1,
            "workerProtocols": [2], "nativeControlProtocol": 1,
        }) + "\n")
    if guardian_daemon:
        program = "Contents/MacOS/swiftmux-guardian"
        arguments = ["swiftmux-guardian", "--config", str(probe_root / "guardian-config.json")]
    elif gateway_daemon:
        program = "Contents/MacOS/swiftmux-gateway"
        arguments = ["swiftmux-gateway", "--guardian-service", guardian_service + ".control",
                     "--guardian-identifier", guardian_service + ".swiftmux-guardian", "--control-service", label]
    else:
        program, arguments = "Contents/MacOS/probe", ["probe", mode]
    with (agents / (label + ".plist")).open("wb") as file:
        plistlib.dump({
            "Label": label, "BundleProgram": program,
            "ProgramArguments": arguments,
            "AssociatedBundleIdentifiers": [label + ".app"],
            "MachServices": {label: True, **({label + ".control": True}
                if guardian_daemon or mode in ("serve-workspace-guardian", "serve-build-guardian") else {})}, "RunAtLoad": True,
            "ProcessType": "Interactive", "EnablePressuredExit": False,
            "EnableTransactions": False,
            **({"StandardErrorPath": str(probe_root / (label + ".stderr")),
                "StandardOutPath": str(probe_root / (label + ".stdout"))}
               if probe_root else {}),
        }, file)
    run("/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp",
        "--sign", identity, str(path))
    run("/usr/bin/codesign", "--verify", "--strict", str(path))
    signing = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(path)],
                             text=True, capture_output=True, check=True).stderr
    if "Authority=Developer ID Application:" not in signing:
        raise RuntimeError("A0 requires a Developer ID Application signature")
    return signing


def wait_for(action, description, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            return action()
        except (RuntimeError, OSError, ValueError, AssertionError) as error:
            last = error
            time.sleep(0.1)
    raise RuntimeError(f"timed out: {description}: {last}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--bin-dir", required=True, type=Path)
    parser.add_argument("--worker-transport", action="store_true",
                        help="qualify supervised guardian/worker XPC in separate signed processes")
    parser.add_argument("--workspace-worker", action="store_true",
                        help="qualify the real workspace worker and gateway control client")
    parser.add_argument("--worker-builds", action="store_true",
                        help="qualify signed immutable build installation, selection and live pins")
    parser.add_argument("--guardian-daemon", action="store_true",
                        help="qualify the exact signed guardian executable and gateway role restriction")
    parser.add_argument("--gateway-daemon", action="store_true",
                        help="qualify exact guardian/gateway executables with an independent native frontend")
    parser.add_argument("--installer", action="store_true",
                        help="qualify durable adoption, maintenance, restart reporting and uninstall with fixture agents")
    args = parser.parse_args()
    binary = args.bin_dir.resolve() / "GuardianLifecycleProbe"
    launcher = args.bin_dir.resolve() / "swmux-launcher"
    if not binary.is_file() or not launcher.is_file():
        parser.error("build GuardianLifecycleProbe and swmux-launcher first")
    if args.installer:
        for product in ("swiftmux-guardian", "swiftmux-gateway", "swiftmux-worker", "swsh"):
            if not (args.bin_dir.resolve() / product).is_file():
                parser.error(f"build {product} first")
        from qualify_installer import qualify_installer
        qualify_installer(args, binary, launcher, run=run, bundle=bundle, wait_for=wait_for)
        return
    if args.gateway_daemon:
        for product in ("swiftmux-guardian", "swiftmux-gateway", "swiftmux-worker", "swsh", "swmux"):
            if not (args.bin_dir.resolve() / product).is_file():
                parser.error(f"build {product} first")
        from qualify_gateway_daemon import qualify_gateway_daemon
        qualify_gateway_daemon(args, binary, launcher, run=run, bundle=bundle, wait_for=wait_for)
        return
    if args.guardian_daemon or args.worker_builds:
        for product in ("swiftmux-worker", "swsh"):
            if not (args.bin_dir.resolve() / product).is_file():
                parser.error(f"build {product} first")
        if args.guardian_daemon:
            if not (args.bin_dir.resolve() / "swiftmux-guardian").is_file():
                parser.error("build swiftmux-guardian first")
            from qualify_guardian_daemon import qualify_guardian_daemon
            qualify_guardian_daemon(args, binary, launcher, run=run, bundle=bundle, wait_for=wait_for)
            return
        from qualify_worker_builds import qualify_worker_builds
        qualify_worker_builds(args, binary, launcher, run=run, bundle=bundle, wait_for=wait_for)
        return
    if args.workspace_worker and not (args.bin_dir.resolve() / "swiftmux-worker").is_file():
        parser.error("build swiftmux-worker first")
    if args.worker_transport or args.workspace_worker:
        qualify_worker_transport(args, binary, launcher)
        return
    root = Path(tempfile.mkdtemp(prefix="swiftty-guardian-qualification-"))
    print(root, flush=True)
    tag = uuid.uuid4().hex
    prefix = "com.chr33s.swiftty.durability-probe." + tag
    guardian_label, gateway_label = prefix + ".guardian", prefix + ".gateway"
    guardian, gateway = root / "Guardian.app", root / "Gateway.app"
    staged, previous = root / "Gateway-next.app", root / "Gateway-previous.app"
    evidence = {"scope": "A0 independent signed registration and real PTY lifetime",
                "production_worker_isolation": False, "root": str(root),
                "revision": run("git", "rev-parse", "HEAD"),
                "os": run("/usr/bin/sw_vers"), "checks": [], "passed": False}
    registered = []

    def invoke(app, *arguments):
        return run(str(app / "Contents/MacOS/probe"), *arguments)

    def status(label):
        return json.loads(invoke(guardian, "status", label))["status"]["_0"]

    def send(command):
        receipt = root / ("receipt-" + uuid.uuid4().hex)
        invoke(guardian, "send", guardian_label,
               command + "; printf done > " + shlex.quote(str(receipt)), str(receipt))

    def state_snapshot(name):
        path = root / (name + ".txt")
        script = ("printf '%s\\n' \"$$\" \"$durability_token\" \"$durability_job\"; "
                  "kill -0 \"$durability_job\" && echo job-alive; "
                  "set -o; jobs -l; echo PROBE-DONE")
        send("{ " + script + "; } > " + shlex.quote(str(path)))

        def read():
            text = path.read_text()
            assert "PROBE-DONE" in text
            lines = text.splitlines()
            assert lines[1] == tag, text
            assert lines[3] == "job-alive", text
            assert any(line.split() == ["monitor", "on"] for line in lines), text
            return {"shell_pid": int(lines[0]), "job_pid": int(lines[2]), "text": text}
        return wait_for(read, name)

    try:
        evidence["guardian_signature"] = bundle(
            guardian, guardian_label, 1, binary, launcher, args.identity)
        bundle(gateway, gateway_label, 1, binary, launcher, args.identity)
        bundle(staged, gateway_label, 2, binary, launcher, args.identity)
        for app in (guardian, gateway):
            invoke(app, "register")
            registered.append(app)
        original = wait_for(lambda: status(guardian_label), "guardian startup")
        gateway_before = wait_for(lambda: status(gateway_label), "gateway startup")
        invoke(guardian, "create", guardian_label)
        send("set +H")
        send(f"durability_token={tag}; sleep 300 & durability_job=$!")
        before = state_snapshot("before")
        evidence["before"] = {"guardian": original, "gateway": gateway_before, **before}
        # Crash only the independently owned, empty gateway fixture.
        os.kill(gateway_before["pid"], signal.SIGKILL)
        wait_for(lambda: status(gateway_label), "gateway Mach reactivation")
        assert status(guardian_label)["server"] == original["server"]
        assert state_snapshot("after-crash")["shell_pid"] == before["shell_pid"]
        evidence["checks"].append("gateway SIGKILL preserves shell and variables")
        invoke(gateway, "unregister")
        registered.remove(gateway)
        gateway.rename(previous)
        staged.rename(gateway)
        invoke(gateway, "register")
        registered.append(gateway)
        gateway_after = wait_for(lambda: status(gateway_label), "updated gateway startup")
        after = state_snapshot("after-update")
        current = status(guardian_label)
        assert current["server"] == original["server"]
        assert current["pid"] == original["pid"]
        assert after["shell_pid"] == before["shell_pid"]
        assert after["job_pid"] == before["job_pid"]
        assert gateway_after["server"] != gateway_before["server"]
        evidence["after"] = {"guardian": current, "gateway": gateway_after, **after}
        evidence["checks"].append("gateway unregister/replace/register preserves guardian, shell, job and job control")
        evidence["passed"] = True
    except Exception as error:
        evidence["error"] = str(error)
        raise
    finally:
        # Terminate only the fixture's panes, then remove only registrations
        # successfully created by this invocation. Keep bundles for diagnosis.
        cleanup = []
        if guardian in registered:
            try:
                invoke(guardian, "end", guardian_label)
            except Exception as error:
                cleanup.append(str(error))
        for app in reversed(registered):
            try:
                invoke(app, "unregister")
            except Exception as error:
                cleanup.append(str(error))
        evidence["cleanup_errors"] = cleanup
        if cleanup:
            evidence["passed"] = False
        (root / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(f"Evidence: {root / 'evidence.json'}", flush=True)
    if not evidence["passed"]:
        raise RuntimeError("qualification cleanup failed; inspect evidence")


def qualify_worker_transport(args, binary, launcher):
    """Qualify raw transport or the real workspace host in isolated signed jobs."""
    root = Path(tempfile.mkdtemp(prefix="swiftty-worker-qualification-"))
    print(root, flush=True)
    prefix = "com.chr33s.swiftty.durability-probe." + uuid.uuid4().hex
    guardian_label, gateway_label = prefix + ".guardian", prefix + ".gateway"
    guardian, gateway = root / "Guardian.app", root / "Gateway.app"
    staged, previous = root / "Gateway-next.app", root / "Gateway-previous.app"
    registered = []
    real_workspace = args.workspace_worker
    worker_binary = args.bin_dir.resolve() / "swiftmux-worker" if real_workspace else None
    evidence = {"scope": "signed supervised worker, XPC and guardian-owned PTY",
                "production_workspace_routing": False,
                "real_workspace_worker": real_workspace, "root": str(root),
                "revision": run("git", "rev-parse", "HEAD"),
                "os": run("/usr/bin/sw_vers"), "checks": [], "passed": False}

    def invoke(app, *arguments):
        return run(str(app / "Contents/MacOS/probe"), *arguments)

    def snapshot():
        return json.loads((root / "guardian.json").read_text())

    def ready():
        state = snapshot()
        assert state["available"] and state.get("worker") and state.get("shell"), state
        if real_workspace:
            proof = json.loads((root / "gateway.json").read_text())
            fields = proof["proof"].split("=", 1)[1].strip().split(":")
            assert fields[0] == "durable" and int(fields[1]) == state["shell"], proof
            assert "m" in fields[3], proof
            os.kill(int(fields[2]), 0)
            assert int(proof["worker"]) == state["worker"], proof
            assert int(run("/bin/ps", "-o", "ppid=", "-p", str(state["worker"]))) == state["guardian"]
        else:
            worker = json.loads((root / "worker.json").read_text())
            assert worker["output"] == "GUARDIAN_READY", worker
            assert int(worker["worker"]) == state["worker"], worker
            assert int(worker["parent"]) == state["guardian"], worker
            assert int(worker["shell"]) == state["shell"], worker
        assert len({state["guardian"], state["worker"], state["shell"]}) == 3
        assert int(run("/bin/ps", "-o", "ppid=", "-p", str(state["shell"]))) == state["guardian"]
        for key in ("guardian", "worker", "shell"):
            os.kill(state[key], 0)
        return state

    def gateway_status():
        if real_workspace:
            proof = json.loads((root / "gateway.json").read_text())
            os.kill(int(proof["gateway"]), 0)
            return {"pid": int(proof["gateway"]), **proof}
        return json.loads(invoke(guardian, "status", gateway_label))["status"]["_0"]

    try:
        evidence["guardian_signature"] = bundle(
            guardian, guardian_label, 1, binary, launcher, args.identity,
            mode="serve-workspace-guardian" if real_workspace else "serve-guardian",
            probe_root=root, worker=worker_binary)
        gateway_options = {"mode": "serve-workspace-gateway", "probe_root": root,
                           "guardian_service": guardian_label} if real_workspace else {}
        bundle(gateway, gateway_label, 1, binary, launcher, args.identity, **gateway_options)
        bundle(staged, gateway_label, 2, binary, launcher, args.identity, **gateway_options)
        for app in (guardian, gateway):
            invoke(app, "register")
            registered.append(app)
        before = wait_for(ready, "supervised worker and real PTY output")
        gateway_before = wait_for(gateway_status, "gateway fixture startup")
        evidence["before"] = before
        evidence["gateway_before"] = gateway_before
        evidence["checks"].append("signed worker authenticates from its own PID and receives PTY output")
        os.kill(gateway_before["pid"], signal.SIGKILL)
        if real_workspace:
            run("/bin/launchctl", "kickstart", "-k", f"gui/{os.geteuid()}/{gateway_label}")

        def restarted_gateway():
            status = gateway_status()
            assert status["pid"] != gateway_before["pid"], status
            return status

        evidence["gateway_restarted"] = wait_for(restarted_gateway, "gateway reactivation")
        assert ready() == before
        invoke(gateway, "unregister")
        registered.remove(gateway)
        gateway.rename(previous)
        if real_workspace:
            (root / "gateway.json").unlink(missing_ok=True)
        staged.rename(gateway)
        invoke(gateway, "register")
        registered.append(gateway)
        gateway_after = wait_for(gateway_status, "replacement gateway")
        if not real_workspace:
            assert gateway_after["server"] != gateway_before["server"]
        evidence["gateway_after"] = gateway_after
        if real_workspace:
            assert gateway_after["build"] == "2", gateway_after
            assert gateway_after["workspace"] == gateway_before["workspace"]
            assert gateway_after["server"] == gateway_before["server"]
            for key in ("gateway_restarted", "gateway_after"):
                assert evidence[key]["proof"] != gateway_before["proof"]
                assert evidence[key]["proof"].split("=", 1)[1] == gateway_before["proof"].split("=", 1)[1]
            evidence["checks"].append("real worker retains graph, frame state, shell variable and job control across gateway replacement")
        assert ready() == before
        evidence["checks"].append("gateway kill and replacement preserve guardian, worker and PTY child")
        os.kill(before["worker"], signal.SIGKILL)

        def unavailable():
            state = snapshot()
            assert not state["available"] and state["workerFinished"], state
            assert state["guardian"] == before["guardian"]
            assert state["shell"] == before["shell"] and not state["shellFinished"]
            os.kill(state["shell"], 0)
            return state

        evidence["after_worker_loss"] = wait_for(unavailable, "worker reap with retained shell")
        evidence["checks"].append("worker SIGKILL is reaped while guardian retains the same PTY child")
        evidence["gateway_pids"] = [gateway_before["pid"], gateway_after["pid"]]
        evidence["passed"] = True
    except Exception as error:
        evidence["error"] = str(error)
        raise
    finally:
        cleanup = []
        if guardian in registered:
            try:
                (root / ("gateway-end" if real_workspace else "end")).touch()

                def ended():
                    if real_workspace:
                        assert (root / "gateway-retired").read_text() == "retired"
                        for key in ("worker", "shell"):
                            try:
                                os.kill(before[key], 0)
                            except ProcessLookupError:
                                continue
                            raise AssertionError(f"retired {key} remains alive")
                        return {"workerFinished": True, "shellFinished": True, "retired": True}
                    state = snapshot()
                    assert state["workerFinished"] and (not state.get("shell") or state["shellFinished"]), state
                    return state

                evidence["ended"] = wait_for(ended, "explicit End and child reap")
            except Exception as error:
                cleanup.append(str(error))
                # If the gateway failed before its command loop, still ask
                # the guardian to reap owned children before unregistering.
                (root / "end").touch()
        for app in reversed(registered):
            try:
                invoke(app, "unregister")
            except Exception as error:
                cleanup.append(str(error))
        evidence["cleanup_errors"] = cleanup
        if cleanup:
            evidence["passed"] = False
        (root / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(f"Evidence: {root / 'evidence.json'}", flush=True)
    if not evidence["passed"]:
        raise RuntimeError("worker qualification cleanup failed; inspect evidence")


if __name__ == "__main__":
    main()
