"""Qualify the exact guardian executable in a unique signed launchd job."""
import ctypes
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import uuid

from qualify_worker_builds import signed_worker_bundle


def qualify_guardian_daemon(args, binary, launcher, *, run, bundle, wait_for):
    root = Path(tempfile.mkdtemp(prefix="swiftty-daemon-qualification-")).resolve()
    print(root, flush=True)
    (root / "Versions").mkdir(mode=0o700)
    session = root / "Session"
    session.mkdir(mode=0o700)
    prefix = "com.chr33s.swiftty.durability-probe." + uuid.uuid4().hex
    guardian_label, gateway_label = prefix + ".guardian", prefix + ".gateway"
    guardian, gateway = root / "Guardian.app", root / "Gateway.app"
    staged, previous, wrong = root / "Gateway-next.app", root / "Gateway-previous.app", root / "Wrong-role.app"
    registered = []
    owned = set()
    evidence = {"scope": "exact signed swiftmux-guardian, restricted gateway identity and worker lifetime",
                "production_gateway": False, "root": str(root),
                "revision": run("git", "rev-parse", "HEAD"), "os": run("/usr/bin/sw_vers"),
                "checks": [], "passed": False}

    def invoke(app, *arguments):
        return run(str(app / "Contents/MacOS/probe"), *arguments)

    def alive(pid):
        try:
            os.kill(int(pid), 0)
            return True
        except ProcessLookupError:
            return False

    def executable_path(pid):
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        library.proc_pidpath.restype = ctypes.c_int
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(int(pid), buffer, len(buffer)) <= 0:
            raise RuntimeError(f"cannot inspect executable for fixture PID {pid}")
        return Path(os.fsdecode(buffer.value)).resolve()

    def proof():
        value = json.loads((session / "gateway.json").read_text())
        fields = value["proof"].split("=", 1)[1].strip().split(":")
        assert fields[0] == "durable" and "m" in fields[3] and fields[4] == "ok", value
        value["shell"], value["job"] = int(fields[1]), int(fields[2])
        value["guardian"] = int(run("/bin/ps", "-o", "ppid=", "-p", value["worker"]))
        assert int(run("/bin/ps", "-o", "ppid=", "-p", fields[1])) == value["guardian"]
        assert int(run("/bin/ps", "-o", "ppid=", "-p", fields[2])) == value["shell"]
        for key in ("guardian", "gateway", "worker", "shell", "job"):
            pid = int(value[key])
            assert alive(pid), (key, pid)
            owned.add(pid)
        executable = executable_path(value["guardian"])
        assert executable == guardian / "Contents/MacOS/swiftmux-guardian", executable
        assert executable_path(value["gateway"]) == gateway / "Contents/MacOS/probe"
        assert executable_path(value["worker"]) == root / "Versions/one/Worker.app/Contents/MacOS/swiftmux-worker"
        return value

    def changed_gateway(before):
        value = proof()
        assert value["gateway"] != before["gateway"], value
        assert value["proof"] != before["proof"], value
        assert value["proof"].split("=", 1)[1] == before["proof"].split("=", 1)[1]
        for key in ("guardian", "worker", "shell", "job", "server", "workspace", "workerBuild",
                    "graphRevision", "graphTab", "graphPane"):
            assert value[key] == before[key], (key, value, before)
        return value

    try:
        signed_worker_bundle(args, root, prefix, "one", 1, run=run)
        evidence["guardian_signature"] = bundle(guardian, guardian_label, 1, binary, launcher,
            args.identity, probe_root=root, guardian_daemon=args.bin_dir.resolve() / "swiftmux-guardian",
            gateway_identifier=gateway_label + ".app")
        workspace = str(uuid.uuid4())
        for app, version in ((gateway, 1), (staged, 2)):
            bundle(app, gateway_label, version, binary, launcher, args.identity,
                   mode="serve-workspace-gateway", probe_root=session,
                   guardian_service=guardian_label, workspace=workspace)
        bundle(wrong, prefix + ".wrong-role", 1, binary, launcher, args.identity)
        invoke(guardian, "prepare-guardian-daemon")
        for app in (guardian, gateway):
            invoke(app, "register")
            registered.append(app)
        evidence["before"] = wait_for(proof, "exact guardian and authorized gateway", timeout=25)
        rejected = subprocess.run([str(wrong / "Contents/MacOS/probe"), "check-gateway-access",
                                   guardian_label + ".control"], capture_output=True, text=True, timeout=10)
        assert rejected.returncode != 0 and "admitted" not in rejected.stdout, rejected.stdout
        evidence["wrong_role"] = {"exit": rejected.returncode, "stderr": rejected.stderr.strip()}
        (session / "gateway-check").touch()

        def authorized_still_works():
            assert (session / "gateway-checked").read_text() == "done"
            return True

        wait_for(authorized_still_works, "authorized control and worker connections remain valid")
        evidence["checks"].append("same-team wrong gateway identifier rejected without revoking authorized access")
        os.kill(int(evidence["before"]["gateway"]), signal.SIGKILL)
        run("/bin/launchctl", "kickstart", "-k", f"gui/{os.geteuid()}/{gateway_label}")
        evidence["restarted"] = wait_for(lambda: changed_gateway(evidence["before"]), "gateway crash restart", timeout=25)
        invoke(gateway, "unregister")
        registered.remove(gateway)
        gateway.rename(previous)
        staged.rename(gateway)
        invoke(gateway, "register")
        registered.append(gateway)
        evidence["replaced"] = wait_for(lambda: changed_gateway(evidence["restarted"]), "signed gateway replacement", timeout=25)
        assert evidence["replaced"]["build"] == "2"
        evidence["checks"].append("exact guardian, pinned worker, shell, job and prior terminal output survive gateway crash and replacement")
        evidence["checks"].append("aggregate discovery establishes graph subscriptions with preserved revision, tab and pane identities")
        assert executable_path(evidence["before"]["worker"]) == root / "Versions/one/Worker.app/Contents/MacOS/swiftmux-worker"
        os.kill(int(evidence["before"]["worker"]), signal.SIGKILL)

        def retained():
            assert not alive(evidence["before"]["worker"])
            assert alive(evidence["before"]["shell"]) and alive(evidence["before"]["job"])
            return True

        wait_for(retained, "worker reaped with shell and job retained")
        (session / "gateway-end").touch()

        def ended():
            assert not alive(evidence["before"]["shell"]) and not alive(evidence["before"]["job"])
            return True

        wait_for(ended, "explicit End reaps retained processes")
        evidence["checks"].append("worker loss retains shell/job until gateway-issued End")
        def retired():
            assert (session / "gateway-retired").read_text() == "retired"
            return True

        wait_for(retired, "gateway observes Forget and absent workspace inventory")
        evidence["checks"].append("shared gateway supervisor completes End/Forget and verifies inventory retirement")
        evidence["passed"] = True
    except Exception as error:
        evidence["error"] = str(error)
        raise
    finally:
        cleanup = []
        for app in reversed(registered):
            try:
                invoke(app, "unregister")
            except Exception as error:
                cleanup.append(str(error))
        for app in registered:
            with (app / "Contents/Info.plist").open("rb") as stream:
                label = plistlib.load(stream)["ProbeService"]
            status = subprocess.run(["/bin/launchctl", "print", f"gui/{os.geteuid()}/{label}"],
                                    capture_output=True, text=True)
            if status.returncode == 0:
                cleanup.append(f"registration remains: {label}")

        def all_gone():
            remaining = [pid for pid in owned if alive(pid)]
            assert not remaining, remaining
            return True

        try:
            evidence["processes_gone"] = wait_for(all_gone, "owned process cleanup")
        except Exception as error:
            cleanup.append(str(error))
        evidence["cleanup_errors"] = cleanup
        if cleanup:
            evidence["passed"] = False
        (root / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(f"Evidence: {root / 'evidence.json'}", flush=True)
    if not evidence["passed"]:
        raise RuntimeError("guardian daemon qualification cleanup failed")
