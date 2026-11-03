"""Signed build-registry qualification used by qualify-guardian-lifecycle.py.

Owns only unique probe bundles and registrations. Both build IDs use the current
worker implementation; this does not prove cross-version semantic compatibility.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid


def signed_worker_bundle(args, root, prefix, build, number, *, run):
    app = root / f"Staged-{build}.app"
    macos = app / "Contents/MacOS"
    resources = app / "Contents/Resources"
    macos.mkdir(parents=True)
    (resources / "terminfo/78").mkdir(parents=True)
    # Copy bytes, not the protected system file's filesystem flags.
    shutil.copyfile("/usr/share/terminfo/78/xterm-256color", resources / "terminfo/78/xterm-256color")
    for name in ("swiftmux-worker", "swmux-launcher", "swsh"):
        shutil.copy2(args.bin_dir.resolve() / name, macos / name)
        run("/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp",
            "--sign", args.identity, "--identifier", prefix + ".worker." + name, str(macos / name))
    (resources / "build.json").write_text(json.dumps({"schema": 1, "build": build,
                                                   "guardianProtocol": 1, "workerProtocol": 2}))
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": prefix + ".worker", "CFBundleName": "SwiftMux Worker Probe",
                      "CFBundleExecutable": "swiftmux-worker", "CFBundlePackageType": "APPL",
                      "CFBundleVersion": str(number), "LSMinimumSystemVersion": "27.0"}, stream)
    run("/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp",
        "--sign", args.identity, str(app))
    run("/usr/bin/codesign", "--verify", "--strict", "--deep", str(app))


def qualify_worker_builds(args, binary, launcher, *, run, bundle, wait_for):
    root = Path(tempfile.mkdtemp(prefix="swiftty-build-qualification-")).resolve()
    print(root, flush=True)
    (root / "Versions").mkdir(mode=0o700)
    prefix = "com.chr33s.swiftty.durability-probe." + uuid.uuid4().hex
    guardian_label = prefix + ".guardian"
    guardian = root / "Guardian.app"
    registered = []
    evidence = {"scope": "signed registry installation, selected builds and live resource pins",
                "same_worker_implementation": True, "production_gateway": False,
                "revision": run("git", "rev-parse", "HEAD"), "os": run("/usr/bin/sw_vers"),
                "root": str(root), "passed": False, "checks": []}

    def invoke(app, *arguments):
        return run(str(app / "Contents/MacOS/probe"), *arguments)


    def inventory():
        return json.loads((root / "inventory.json").read_text())

    def gateway_ready(directory, build):
        proof = json.loads((directory / "gateway.json").read_text())
        assert proof["workerBuild"] == build, proof
        fields = proof["proof"].split("=", 1)[1].strip().split(":")
        assert fields[0] == "durable" and "m" in fields[3] and fields[4] == "ok", proof
        for pid in (proof["gateway"], proof["worker"], fields[1], fields[2]):
            os.kill(int(pid), 0)
        proof["guardian"] = int(run("/bin/ps", "-o", "ppid=", "-p", proof["worker"]))
        assert int(run("/bin/ps", "-o", "ppid=", "-p", fields[1])) == proof["guardian"]
        assert int(run("/bin/ps", "-o", "ppid=", "-p", fields[2])) == int(fields[1])
        items = inventory()
        record = next(item for item in items if item["authority"]["workspace"] == proof["workspace"])
        assert record["worker"]["pid"] == int(proof["worker"]), record
        assert record["worker"]["build"] == build and record["available"], record
        assert record["panes"][0]["pid"] == int(fields[1]), record
        return proof

    def expect_file(name, value):
        text = (root / name).read_text()
        assert text == value, text
        return text

    try:
        signed_worker_bundle(args, root, prefix, "one", 1, run=run)
        signed_worker_bundle(args, root, prefix, "two", 2, run=run)
        evidence["guardian_signature"] = bundle(guardian, guardian_label, 1, binary, launcher,
            args.identity, mode="serve-build-guardian", probe_root=root)
        gateways = []
        for number in (1, 2):
            directory = root / f"Session-{number}"
            directory.mkdir(mode=0o700)
            app = root / f"Gateway-{number}.app"
            label = prefix + f".gateway-{number}"
            bundle(app, label, 1, binary, launcher, args.identity, mode="serve-workspace-gateway",
                   probe_root=directory, guardian_service=guardian_label, workspace=str(uuid.uuid4()))
            gateways.append((app, label, directory))
        invoke(guardian, "register")
        registered.append(guardian)
        first, first_label, first_directory = gateways[0]
        invoke(first, "register")
        registered.append(first)
        evidence["first"] = wait_for(lambda: gateway_ready(first_directory, "one"), "first pinned workspace", timeout=25)
        (root / "select-two").touch()
        wait_for(lambda: expect_file("selected", "two"), "select second signed build")
        second, _, second_directory = gateways[1]
        invoke(second, "register")
        registered.append(second)
        evidence["second"] = wait_for(lambda: gateway_ready(second_directory, "two"), "second pinned workspace", timeout=25)
        assert evidence["first"]["guardian"] == evidence["second"]["guardian"]
        assert evidence["first"]["worker"] != evidence["second"]["worker"]
        assert len(inventory()) == 2
        (root / "collect-one").touch()
        wait_for(lambda: expect_file("collection", "pinned"), "live pin rejects collection")
        assert (root / "Versions/one/Worker.app").is_dir()
        evidence["checks"].append("new workspace uses build two; live build one cannot be collected after rollback retention clears")
        run("/bin/launchctl", "kickstart", "-k", f"gui/{os.geteuid()}/{first_label}")

        def reattached():
            proof = gateway_ready(first_directory, "one")
            assert proof["gateway"] != evidence["first"]["gateway"], proof
            assert proof["proof"] != evidence["first"]["proof"], proof
            assert proof["proof"].split("=", 1)[1] == evidence["first"]["proof"].split("=", 1)[1]
            assert proof["worker"] == evidence["first"]["worker"]
            assert proof["server"] == evidence["first"]["server"]
            return proof

        evidence["reattached"] = wait_for(reattached, "reattach old pinned worker", timeout=25)
        evidence["inventory"] = inventory()
        evidence["checks"].append("gateway replacement preserves old worker, shell, job, prior output and version-specific terminfo")
        (root / "end-all").touch()

        def ended():
            items = inventory()
            assert all(item["worker"]["finished"] and all(pane["finished"] for pane in item["panes"]) for item in items), items
            return items

        evidence["ended"] = wait_for(ended, "both workspaces reaped")
        (root / "forget-all").touch()
        wait_for(lambda: expect_file("forgotten", "done"), "workspace retirement")
        (root / "collection").unlink()
        (root / "collect-one").touch()
        wait_for(lambda: expect_file("collection", "collected"), "unpin old build after retirement")
        assert not (root / "Versions/one").exists()
        assert (root / "Versions/two/Worker.app").is_dir()
        evidence["selection"] = json.loads((root / "Versions/.selection.json").read_text())
        assert evidence["selection"]["selected"] == "two"
        evidence["checks"].append("old build collects only after explicit End and retirement; selected build remains")
        evidence["passed"] = True
    except Exception as error:
        evidence["error"] = str(error)
        raise
    finally:
        cleanup = []
        if guardian in registered:
            (root / "end-all").touch()
        for app in reversed(registered):
            try:
                invoke(app, "unregister")
            except Exception as error:
                cleanup.append(str(error))
        for app in registered:
            with (app / "Contents/Info.plist").open("rb") as stream:
                label = plistlib.load(stream)["ProbeService"]
            result = subprocess.run(["/bin/launchctl", "print", f"gui/{os.geteuid()}/{label}"],
                                    capture_output=True, text=True)
            if result.returncode == 0:
                cleanup.append(f"registration remains: {label}")
        owned = set()
        for name in ("first", "second", "reattached"):
            if name in evidence:
                proof = evidence[name]
                fields = proof["proof"].split("=", 1)[1].strip().split(":")
                owned.update(int(pid) for pid in (proof["guardian"], proof["gateway"], proof["worker"], fields[1], fields[2]))

        def processes_gone():
            for pid in owned:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    continue
                raise RuntimeError(f"qualification process remains: {pid}")
            return True

        try:
            evidence["processes_gone"] = wait_for(processes_gone, "owned process cleanup")
        except Exception as error:
            cleanup.append(str(error))
        evidence["cleanup_errors"] = cleanup
        if cleanup:
            evidence["passed"] = False
        (root / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(f"Evidence: {root / 'evidence.json'}", flush=True)
    if not evidence["passed"]:
        raise RuntimeError("signed build qualification cleanup failed")
