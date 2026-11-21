"""Durable installer qualification with isolated fixture agents (UA8).

A legacy monolithic mux agent with a live session moves to a signed guardian
and gateway through `DurableInstallation`: declined and confirmed adoption,
guardian maintenance behind the empty-state barrier, a guardian restart
reported as ended sessions (never restored) and uninstall. Every agent is a
uniquely named fixture; the installed app is not touched.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import uuid

from qualify_worker_builds import signed_worker_bundle


def qualify_installer(args, binary, launcher, *, run, bundle, wait_for):
    root = Path(tempfile.mkdtemp(prefix="swiftty-installer-qualification-")).resolve()
    print(root, flush=True)
    (root / "Versions").mkdir(mode=0o700)
    prefix = "com.chr33s.swiftty.durability-probe." + uuid.uuid4().hex
    legacy_label = prefix + ".legacy"
    guardian_label, gateway_label = prefix + ".guardian", prefix + ".gateway"
    legacy, guardian = root / "Legacy.app", root / "Guardian.app"
    gateway, installer = root / "Gateway.app", root / "Installer.app"
    record = root / "Support" / "durable-install.json"
    labels = {legacy: legacy_label, guardian: guardian_label, gateway: gateway_label}
    evidence = {"scope": "durable installer with isolated fixture agents",
                "root": str(root), "revision": run("git", "rev-parse", "HEAD"),
                "os": run("/usr/bin/sw_vers"), "passed": False, "checks": []}
    owned = set()

    def invoke(app, *arguments):
        return run(str(app / "Contents/MacOS/probe"), *arguments)

    def install(action, answer):
        return run(str(installer / "Contents/MacOS/probe"), "durable-install", action,
                   legacy_label, str(legacy), str(guardian), str(gateway), gateway_label,
                   str(record), answer, timeout=120).splitlines()[-1]

    def job_pid(label):
        result = subprocess.run(["/bin/launchctl", "print", f"gui/{os.geteuid()}/{label}"],
                                capture_output=True, text=True)
        if result.returncode != 0:
            return None
        match = re.search(r"^\s*pid = (\d+)\s*$", result.stdout, re.MULTILINE)
        return int(match.group(1)) if match else 0

    def need(value, condition=None):
        assert (condition(value) if condition else value), value
        return value

    def alive(pid):
        try:
            os.kill(int(pid), 0)
            return True
        except ProcessLookupError:
            return False

    def descendants(pid):
        found, frontier = set(), [pid]
        while frontier:
            out = subprocess.run(["/usr/bin/pgrep", "-P", str(frontier.pop())],
                                 capture_output=True, text=True).stdout.split()
            for child in map(int, out):
                if child not in found:
                    found.add(child)
                    frontier.append(child)
        return found

    try:
        signed_worker_bundle(args, root, prefix, "one", 1, run=run)
        bundle(legacy, legacy_label, 1, binary, launcher, args.identity)
        bundle(guardian, guardian_label, 1, binary, launcher, args.identity,
               probe_root=root, guardian_daemon=args.bin_dir.resolve() / "swiftmux-guardian",
               gateway_identifier=gateway_label + ".swiftmux-gateway")
        bundle(gateway, gateway_label, 1, binary, launcher, args.identity,
               probe_root=root, guardian_service=guardian_label,
               gateway_daemon=args.bin_dir.resolve() / "swiftmux-gateway")
        bundle(installer, prefix + ".installer", 1, binary, launcher, args.identity)
        invoke(guardian, "prepare-guardian-daemon")

        # The monolithic agent with one live shell.
        invoke(legacy, "register")
        invoke(installer, "create", legacy_label)
        legacy_pid = wait_for(lambda: need(job_pid(legacy_label)), "legacy agent running")
        shells = wait_for(lambda: need(descendants(legacy_pid)), "legacy shell running")
        owned.update(shells | {legacy_pid})

        assert install("adopt", "decline") == "declined:1"
        assert job_pid(legacy_label) == legacy_pid and all(map(alive, shells))
        assert job_pid(guardian_label) is None and job_pid(gateway_label) is None
        assert not record.exists()
        evidence["checks"].append("declined adoption leaves the legacy agent and its shell running; nothing is registered or recorded")

        adopted = install("adopt", "confirm")
        assert adopted.startswith("installed:"), adopted
        first = adopted.split(":", 1)[1]
        assert job_pid(legacy_label) is None
        wait_for(lambda: need(not any(map(alive, shells))), "legacy shell ended")
        assert job_pid(guardian_label) and job_pid(gateway_label)
        owned.update({job_pid(guardian_label), job_pid(gateway_label)})
        assert json.loads(record.read_text())["phase"] == "installed"
        assert (record.stat().st_mode & 0o077) == 0
        evidence["adopted"] = first
        evidence["checks"].append("confirmed adoption ends legacy sessions, unregisters the legacy agent, registers guardian then gateway and records the verified incarnation; no shell is adopted")

        # A durable session, then maintenance behind the empty-state barrier.
        workspace = str(uuid.uuid4())
        invoke(installer, "native-client", gateway_label, workspace, "create")
        guardian_pid = job_pid(guardian_label)
        durable_shells = wait_for(lambda: need(descendants(guardian_pid)), "durable shell running")
        owned.update(durable_shells)

        # An ordinary gateway update (UA4): the running gateway checks the
        # staged candidate under the barrier and hands over; the installer
        # swaps the bundle; the new gateway finishes. The session survives.
        candidate = root / "Gateway-next.app"
        bundle(candidate, gateway_label, 2, binary, launcher, args.identity,
               probe_root=root, guardian_service=guardian_label,
               gateway_daemon=args.bin_dir.resolve() / "swiftmux-gateway")
        old_gateway = job_pid(gateway_label)
        updated = run(str(installer / "Contents/MacOS/probe"), "durable-install", "update-gateway",
                      legacy_label, str(legacy), str(guardian), str(gateway), gateway_label,
                      str(record), "confirm", str(candidate), timeout=120).splitlines()[-1]
        assert updated == "updated:2", updated
        new_gateway = wait_for(lambda: need(job_pid(gateway_label),
                                            lambda pid: pid not in (None, 0, old_gateway)),
                               "updated gateway running")
        owned.add(new_gateway)
        assert job_pid(guardian_label) == guardian_pid and all(map(alive, durable_shells))
        listed = json.loads(invoke(installer, "native-client", gateway_label, workspace, "list"))
        assert any(item["workspace"].lower() == workspace.lower()
                   and "available" in item["state"] for item in listed), listed
        build_file = gateway / "Contents/Resources/gateway-build.json"
        assert json.loads(build_file.read_text())["build"] == "2"
        assert not (root / "Support" / "gateway-update.json").exists()
        evidence["checks"].append("signed gateway update: the running gateway validates the staged candidate under the admission barrier and hands over; the installer swaps the bundle and re-registers; the new gateway verifies itself and resumes admission; guardian, workspace and shell are unchanged")
        assert install("maintain", "decline") == "declined:1"
        assert job_pid(guardian_label) == guardian_pid and all(map(alive, durable_shells))
        maintained = install("maintain", "confirm")
        assert maintained.startswith("maintained:"), maintained
        second = maintained.split(":", 1)[1]
        assert second != first
        assert job_pid(guardian_label) not in (None, guardian_pid)
        assert not any(map(alive, durable_shells))
        owned.update({job_pid(guardian_label), job_pid(gateway_label)})
        assert install("startup", "decline") == f"running:{second}"
        evidence["checks"].append("guardian maintenance is refused while sessions live unless confirmed; confirmed maintenance ends them, restarts the guardian with a new incarnation and records it")

        # A guardian restart (as after reboot) loses sessions and says so.
        invoke(installer, "native-client", gateway_label, str(uuid.uuid4()), "create")
        run("/bin/launchctl", "kickstart", "-k", f"gui/{os.geteuid()}/{guardian_label}")
        ended = wait_for(lambda: need(install("startup", "decline"),
                                     lambda value: value.startswith("sessions-ended:")),
                         "restart reported", timeout=30)
        assert ended.split(":")[1] == second, ended
        third = ended.split(":")[2]
        assert install("startup", "decline") == f"running:{third}"
        owned.update({job_pid(guardian_label) or 0, job_pid(gateway_label) or 0})
        evidence["checks"].append("after a guardian restart the installer reports ended sessions with the old and new incarnations, never restoration, and then reports the new guardian as running")

        assert install("uninstall", "confirm") == "uninstalled"
        assert job_pid(guardian_label) is None and job_pid(gateway_label) is None
        assert job_pid(legacy_label) is None
        assert install("startup", "decline") == "not-installed"
        evidence["checks"].append("uninstall ends confirmed sessions, removes both durable agents and the record, and does not reinstate the legacy agent")
        evidence["passed"] = True
    except Exception as error:
        evidence["error"] = str(error)
        raise
    finally:
        cleanup = []
        for app, label in labels.items():
            if job_pid(label) is not None:
                try:
                    invoke(app, "unregister")
                except Exception as error:
                    cleanup.append(str(error))
            if job_pid(label) is not None:
                cleanup.append(f"registration remains: {label}")

        def processes_gone():
            for pid in owned:
                if pid and alive(pid):
                    raise RuntimeError(f"qualification process remains: {pid}")
            return True

        try:
            wait_for(processes_gone, "owned process cleanup")
        except Exception as error:
            cleanup.append(str(error))
        evidence["cleanup_errors"] = cleanup
        if cleanup:
            evidence["passed"] = False
        (root / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(f"Evidence: {root / 'evidence.json'}", flush=True)
    if not evidence["passed"]:
        raise RuntimeError("installer qualification failed")
