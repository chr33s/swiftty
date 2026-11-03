"""Exact gateway/guardian launchd qualification with a separate native client."""
import ctypes
import json
import os
from pathlib import Path
import re
import pty
import select
import time
import signal
import shutil
import subprocess
import tempfile
import uuid

from qualify_worker_builds import signed_worker_bundle


def qualify_gateway_daemon(args, binary, launcher, *, run, bundle, wait_for):
    root = Path(tempfile.mkdtemp(prefix="swiftty-gateway-qualification-")).resolve()
    print(root, flush=True)
    (root / "Versions").mkdir(mode=0o700)
    prefix = "com.chr33s.swiftty.durability-probe." + uuid.uuid4().hex
    guardian_label, gateway_label = prefix + ".guardian", prefix + ".gateway"
    guardian, gateway = root / "Guardian.app", root / "Gateway.app"
    staged, previous, frontend = root / "Gateway-next.app", root / "Gateway-previous.app", root / "Frontend.app"
    workspace = str(uuid.uuid4())
    registered, owned = [], set()
    evidence = {"scope": "exact signed guardian and gateway with independent native frontend",
                "root": str(root), "revision": run("git", "rev-parse", "HEAD"),
                "os": run("/usr/bin/sw_vers"), "passed": False, "checks": []}

    def invoke(app, *arguments):
        return run(str(app / "Contents/MacOS/probe"), *arguments)

    def client(action, prior=None):
        arguments = ["native-client", gateway_label, workspace, action]
        if prior:
            arguments.append(prior["proof"])
        return invoke(frontend, *arguments)

    def alive(pid):
        try:
            os.kill(int(pid), 0)
            return True
        except ProcessLookupError:
            return False

    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int

    def executable(pid):
        buffer = ctypes.create_string_buffer(4096)
        assert library.proc_pidpath(int(pid), buffer, len(buffer)) > 0, pid
        return Path(os.fsdecode(buffer.value)).resolve()

    def daemon_pid(label, path):
        status = run("/bin/launchctl", "print", f"gui/{os.geteuid()}/{label}")
        match = re.search(r"^\s*pid = (\d+)\s*$", status, re.MULTILINE)
        assert match, status
        pid = int(match.group(1))
        assert executable(pid) == path, (pid, executable(pid), path)
        owned.add(pid)
        return pid

    def gateway_pid():
        return daemon_pid(gateway_label, gateway / "Contents/MacOS/swiftmux-gateway")

    def ready():
        gateway_pid()
        json.loads(client("list"))
        return True

    def proof(action, prior=None):
        result = json.loads(client(action, prior))
        result["gateway"] = gateway_pid()
        result["guardian"] = daemon_pid(guardian_label, guardian / "Contents/MacOS/swiftmux-guardian")
        fields = result["proof"].split("=", 1)[1].split(":")
        assert fields[0] == "durable" and "m" in fields[3], fields
        result["shell"], result["job"] = int(fields[1]), int(fields[2])
        assert alive(result["shell"]) and alive(result["job"])
        owned.update((result["shell"], result["job"]))
        children = run("/usr/bin/pgrep", "-P", str(result["guardian"])).splitlines()
        workers = [int(pid) for pid in children if executable(pid) == root / "Versions/one/Worker.app/Contents/MacOS/swiftmux-worker"]
        assert len(workers) == 1, workers
        result["worker"] = workers[0]
        owned.add(workers[0])
        assert int(result["frontend"]) not in (result["guardian"], result["gateway"], result["worker"])
        if prior:
            for key in ("guardian", "worker", "shell", "job", "workspace", "server", "tab", "pane"):
                assert result[key] == prior[key], (key, result, prior)
            assert result["gateway"] != prior["gateway"]
            assert result["proof"].split("=", 1)[1] == prior["proof"].split("=", 1)[1]
        return result

    try:
        signed_worker_bundle(args, root, prefix, "one", 1, run=run)
        bundle(guardian, guardian_label, 1, binary, launcher, args.identity,
               probe_root=root, guardian_daemon=args.bin_dir.resolve() / "swiftmux-guardian",
               gateway_identifier=gateway_label + ".swiftmux-gateway")
        for app, version in ((gateway, 1), (staged, 2)):
            bundle(app, gateway_label, version, binary, launcher, args.identity,
                   probe_root=root, guardian_service=guardian_label,
                   gateway_daemon=args.bin_dir.resolve() / "swiftmux-gateway")
        bundle(frontend, prefix + ".frontend", 1, binary, launcher, args.identity,
               cli=args.bin_dir.resolve() / "swmux")
        artifact = json.loads(invoke(frontend, "validate-gateway-candidate", str(staged),
                                     gateway_label + ".app", gateway_label + ".swiftmux-gateway",
                                     guardian_label + ".control", guardian_label + ".swiftmux-guardian", gateway_label))
        assert artifact == {"schema": 1, "build": "2", "guardianProtocol": 1,
                            "workerProtocols": [2], "nativeControlProtocol": 1}, artifact
        gateway_versions = root / "GatewayVersions"
        gateway_versions.mkdir(mode=0o700)
        staged_manifest = json.loads(invoke(frontend, "stage-gateway-candidate", str(staged),
                                     gateway_label + ".app", gateway_label + ".swiftmux-gateway",
                                     guardian_label + ".control", guardian_label + ".swiftmux-guardian",
                                     gateway_label, str(gateway_versions)))
        assert staged_manifest == artifact
        published = gateway_versions / artifact["build"] / "Gateway.app"
        assert published.is_dir()
        # Exercise the private published copy, not the original candidate path.
        shutil.rmtree(staged)
        shutil.copytree(published, staged)
        evidence["staged_candidate"] = str(published)
        evidence["checks"].append("signed candidate is copied, revalidated and atomically staged without replacing existing versions; lifecycle replacement uses that published copy")
        evidence["candidate_manifest"] = artifact
        evidence["checks"].append("independent signed frontend validates staged gateway and nested executable identity before accepting the sealed compatibility declaration")
        invoke(guardian, "prepare-guardian-daemon")
        for app in (guardian, gateway):
            invoke(app, "register")
            registered.append(app)
        wait_for(ready, "exact gateway ready", timeout=25)
        evidence["before"] = proof("create")
        cli = str(frontend / "Contents/MacOS/swmux")
        def command(*arguments):
            return run(cli, "--gateway-service", gateway_label, *arguments)

        assert workspace.upper() in command("list")
        assert "1 retained workspace(s)" in command("status")
        initial_children = set(run("/usr/bin/pgrep", "-P", str(evidence["before"]["guardian"])).splitlines())
        created = command("new", "-d", "-s", "cli-detached", "--", "/bin/sh", "-c", "exec sleep 300")
        created_id = str(uuid.UUID(created.removeprefix("created "))).upper()
        assert created_id in command("list")
        new_children = set(run("/usr/bin/pgrep", "-P", str(evidence["before"]["guardian"])).splitlines()) - initial_children
        assert len(new_children) == 2, new_children
        owned.update(map(int, new_children))
        command("end", "-t", created_id)

        def cli_retired():
            assert created_id not in command("list")
            assert all(not alive(pid) for pid in new_children)
            return True

        wait_for(cli_retired, "CLI-created worker and shell retired")
        evidence["cli_workspace"] = created_id
        evidence["checks"].append("signed swmux lists inventory, reports status, creates once and ends the explicit workspace ID")
        config_root = root / "CLI-config"
        config_root.mkdir(mode=0o700)
        cli_environment = {**os.environ, "XDG_CONFIG_HOME": str(config_root)}
        master, slave = pty.openpty()
        interactive = subprocess.Popen([cli, "--gateway-service", gateway_label, "--allow-host", "attach", "-t", workspace],
                                       stdin=slave, stdout=slave, stderr=slave, close_fds=True, env=cli_environment)
        os.close(slave)
        transcript = bytearray()

        def drain_terminal():
            # Rendering writes synchronously to the outer tty. Lifecycle polling
            # must keep consuming it or the harness itself stops frontend progress.
            for _ in range(16):
                if not select.select([master], [], [], 0)[0]:
                    break
                data = os.read(master, 65536)
                if not data:
                    break
                transcript.extend(data)

        def terminal_text(marker, start=0):
            deadline = time.monotonic() + 10
            while marker not in transcript[start:]:
                assert interactive.poll() is None, (interactive.returncode, bytes(transcript[-2000:]))
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"CLI terminal missing {marker!r}: {bytes(transcript[-2000:])!r}")
                if select.select([master], [], [], 0.1)[0]:
                    transcript.extend(os.read(master, 65536))

        try:
            terminal_text(b"independent-frontend")
            os.write(master, b"printf 'cli-native-%s\\n' 'ok'\r")
            terminal_text(b"cli-native-ok")
            evidence["attached_recovery"] = []
            for name, sig in (("graceful", signal.SIGTERM), ("crashed", signal.SIGKILL), ("replaced", None)):
                old_gateway = gateway_pid()
                start = len(transcript)
                if sig is not None:
                    os.kill(old_gateway, sig)
                else:
                    invoke(gateway, "unregister")
                    registered.remove(gateway)
                    gateway.rename(root / "Gateway-before-attached.app")
                    staged.rename(gateway)

                def stopped_attached():
                    drain_terminal()
                    assert not alive(old_gateway)
                    for key in ("guardian", "worker", "shell", "job"):
                        assert alive(evidence["before"][key]), key
                    assert interactive.poll() is None
                    return True

                wait_for(stopped_attached, name + " attached gateway stopped")
                if sig is not None:
                    run("/bin/launchctl", "kickstart", f"gui/{os.geteuid()}/{gateway_label}")
                else:
                    invoke(gateway, "register")
                    registered.append(gateway)

                def reattached():
                    drain_terminal()
                    assert gateway_pid() != old_gateway
                    records = json.loads(client("list"))
                    assert len(records) == 1 and records[0].get("summary", {}).get("isAttached") is True, records
                    assert interactive.poll() is None
                    return True

                wait_for(reattached, name + " signed CLI automatically reattached", timeout=25)
                terminal_text(b"cli-native-ok", start=start)
                marker = "cli-recovered-" + name
                command_bytes = ("printf 'cli-recovered-%s=%s:%s:%s\\n' '" + name
                                 + "' \"$SWMUX_PROBE\" \"$$\" \"$SWMUX_JOB\"\r").encode()
                os.write(master, command_bytes)
                expected = f"{marker}=durable:{evidence['before']['shell']}:{evidence['before']['job']}"
                terminal_text(expected.encode(), start=start)
                evidence["attached_recovery"].append({"event": name, "gateway_before": old_gateway,
                    "gateway_after": gateway_pid(), "frontend": interactive.pid, "proof": expected})
            evidence["checks"].append("same signed swmux process automatically reattaches after SIGTERM, SIGKILL and signed gateway replacement with retained shell variables, shell/job PIDs and output")
            os.write(master, b"\x02d")
            deadline = time.monotonic() + 10
            while interactive.poll() is None:
                if time.monotonic() >= deadline:
                    sample = subprocess.run(["/usr/bin/sample", str(interactive.pid), "1", "1"], capture_output=True, text=True, timeout=8)
                    (root / "cli-detach-sample.txt").write_text(sample.stdout + sample.stderr)
                    raise RuntimeError("CLI detach timed out; process sample retained")
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        transcript.extend(os.read(master, 65536))
                    except OSError:
                        break
            assert interactive.wait(timeout=2) == 0
        finally:
            if interactive.poll() is None:
                interactive.terminate()
                try:
                    interactive.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    interactive.kill()
                    interactive.wait(timeout=5)
            os.close(master)
            (root / "cli-terminal.bin").write_bytes(transcript)
        evidence["checks"].append("signed swmux attaches through gateway, renders real shell output and detaches without End")
        evidence["after_attached"] = proof("inspect", evidence["before"])
        previous_proof = evidence["after_attached"]
        # The attached pass consumed build 2; stage build 3 for detached update.
        bundle(staged, gateway_label, 3, binary, launcher, args.identity,
               probe_root=root, guardian_service=guardian_label,
               gateway_daemon=args.bin_dir.resolve() / "swiftmux-gateway")
        for name, sig in (("graceful", signal.SIGTERM), ("crashed", signal.SIGKILL)):
            os.kill(previous_proof["gateway"], sig)

            def stopped():
                assert not alive(previous_proof["gateway"])
                assert alive(previous_proof["shell"]) and alive(previous_proof["job"])
                return True

            wait_for(stopped, name + " gateway stopped; shell and job retained")
            run("/bin/launchctl", "kickstart", f"gui/{os.geteuid()}/{gateway_label}")
            wait_for(ready, name + " gateway ready", timeout=25)
            evidence[name] = proof("inspect", previous_proof)
            previous_proof = evidence[name]
        invoke(gateway, "unregister")
        registered.remove(gateway)
        gateway.rename(previous)
        staged.rename(gateway)
        invoke(gateway, "register")
        registered.append(gateway)
        wait_for(ready, "replacement gateway ready", timeout=25)
        evidence["replaced"] = proof("inspect", previous_proof)
        evidence["checks"].append("separate frontend preserves terminal output, graph, shell variables and job control through graceful exit, SIGKILL and signed bundle replacement")
        os.kill(evidence["before"]["worker"], signal.SIGKILL)

        def unavailable():
            assert not alive(evidence["before"]["worker"])
            assert alive(evidence["before"]["shell"]) and alive(evidence["before"]["job"])
            return True

        wait_for(unavailable, "worker reaped with processes retained")
        assert client("end") == "retired"

        def ended():
            assert not alive(evidence["before"]["shell"]) and not alive(evidence["before"]["job"])
            return True

        wait_for(ended, "targeted End reaped processes")
        evidence["checks"].append("separate frontend ends unavailable workspace and observes absent inventory")
        evidence["passed"] = True
    except Exception as error:
        evidence["error"] = str(error)
        raise
    finally:
        errors = []
        for app in reversed(registered):
            try:
                invoke(app, "unregister")
            except Exception as error:
                errors.append(str(error))
        for label in (gateway_label, guardian_label):
            status = subprocess.run(["/bin/launchctl", "print", f"gui/{os.geteuid()}/{label}"], capture_output=True)
            if status.returncode == 0:
                errors.append("registration remains: " + label)

        def gone():
            remaining = [pid for pid in owned if alive(pid)]
            assert not remaining, remaining
            return True

        try:
            evidence["processes_gone"] = wait_for(gone, "owned processes gone")
        except Exception as error:
            errors.append(str(error))
        evidence["cleanup_errors"] = errors
        if errors:
            evidence["passed"] = False
        (root / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(f"Evidence: {root / 'evidence.json'}", flush=True)
    if not evidence["passed"]:
        raise RuntimeError("gateway qualification cleanup failed")
