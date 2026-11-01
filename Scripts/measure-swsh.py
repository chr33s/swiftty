#!/usr/bin/env python3
"""Darwin release measurements; writes raw samples and reproducible build metadata.

Wall times use the ordinary release executable. Allocation/RSS observations use a
separate release build linked to a constructor/destructor measurement library.
No instrumentation or private measurement option is added to the shipped shell.
"""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import signal
import statistics
import subprocess
import sys
import tempfile
import time

from swsh_pty import PtyShell

ROOT = Path(__file__).resolve().parent.parent


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True, stderr=subprocess.STDOUT).strip()


def build(*args):
    subprocess.run(args, cwd=ROOT, check=True, stdout=sys.stderr, stderr=sys.stderr)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def summarize(values):
    values = sorted(values)
    return {"count": len(values), "minimum": values[0], "median": statistics.median(values),
            "p95": values[math.ceil(len(values) * .95) - 1], "maximum": values[-1]}


def run(binary, source, data=b"", payload=None):
    arguments = ["-c", source]
    descriptors = ()
    if payload is not None:
        payload.seek(0)
        descriptors = (payload.fileno(),)
        arguments = ["--swsh-builtin", str(payload.fileno())]
    started = time.perf_counter_ns()
    process = subprocess.Popen([str(binary), *arguments], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True, pass_fds=descriptors)
    try:
        output, error = process.communicate(data, timeout=30)
    except BaseException:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise
    elapsed = time.perf_counter_ns() - started
    if process.returncode != 0:
        raise RuntimeError(f"benchmark exited {process.returncode}: {error[:2000]!r}")
    return elapsed, output, error, process.pid


def timed(binary, source, repetitions, data=b"", expected_stdout=b"", expected_stderr=b"", payload=None):
    samples = []
    for index in range(repetitions + 2):
        elapsed, output, error, _ = run(binary, source, data, payload)
        if output != expected_stdout or error != expected_stderr:
            raise RuntimeError("benchmark output differed from its expected bytes")
        if index >= 2:
            samples.append(elapsed)
    return {"wall_ns": samples, "summary_ns": summarize(samples)}


def allocations(binary, source, expected_workers):
    samples = []
    for _ in range(5):
        _, output, error, root_pid = run(binary, source)
        if output:
            raise RuntimeError("instrumented benchmark produced unexpected stdout")
        records = []
        for line in error.splitlines():
            prefix = b"SWSH_MEASURE "
            if not line.startswith(prefix):
                raise RuntimeError(f"unexpected instrumented stderr: {line!r}")
            records.append(json.loads(line[len(prefix):]))
        roots = [record for record in records if record["pid"] == root_pid]
        workers = [record for record in records if record["pid"] != root_pid]
        if len(roots) != 1 or len(workers) != expected_workers:
            raise RuntimeError(f"incomplete instrumentation: {len(roots)} roots, {len(workers)} workers")
        if len({record["pid"] for record in records}) != len(records):
            raise RuntimeError("duplicate instrumentation record")
        if any(record["main_thread_allocations"] <= 0 or record["peak_rss_bytes"] <= 0 for record in records):
            raise RuntimeError("measurement hook did not observe allocations or RSS")
        samples.append({"root": roots[0], "workers": workers})
    summary = {}
    for role in ("root", "workers"):
        records = [record for sample in samples for record in
                   ([sample["root"]] if role == "root" else sample["workers"])]
        if records:
            summary[role] = {key: summarize([record[key] for record in records])
                             for key in ("main_thread_allocations", "all_thread_allocations", "peak_rss_bytes")}
    return {"samples": samples, "summary": summary}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=30)
    args = parser.parse_args()
    if sys.platform != "darwin" or args.samples < 5:
        parser.error("requires Darwin and at least five samples")
    build("swift", "build", "-c", "release", "--product", "swsh", "--disable-automatic-resolution")
    binary = Path(command("swift", "build", "-c", "release", "--show-bin-path")) / "swsh"
    scratch = ROOT / ".build" / "swsh-measurement"
    scratch.mkdir(parents=True, exist_ok=True)
    library = scratch / "libSwshMeasurement.dylib"
    build("xcrun", "clang", "-O3", "-mmacosx-version-min=27.0", "-dynamiclib", "-o", str(library),
          "-I", str(ROOT / "Sources/CAllocCounter/include"),
          str(ROOT / "Sources/CAllocCounter/CAllocCounter.c"),
          str(ROOT / "Benchmarks/Swsh/AllocationProbe.c"),
          "-install_name", str(library))
    instrument_flags = ["--scratch-path", str(scratch), "-c", "release", "-Xlinker", str(library)]
    build("swift", "build", *instrument_flags, "--product", "swsh", "--disable-automatic-resolution")
    instrumented = Path(command("swift", "build", *instrument_flags, "--show-bin-path")) / "swsh"
    source_files = [ROOT / "Package.swift", ROOT / "Package.resolved"]
    for folder in ("Swsh", "SwshCLI", "CSwshSupport"):
        source_files.extend(path for path in (ROOT / "Sources" / folder).rglob("*") if path.is_file())
    source_hash = hashlib.sha256()
    for path in sorted(source_files):
        source_hash.update(str(path.relative_to(ROOT)).encode() + b"\0" + path.read_bytes() + b"\0")
    result = {
        "schema": 2, "recorded_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "host": {"os": command("sw_vers"), "architecture": platform.machine(),
                 "model": command("sysctl", "-n", "hw.model"),
                 "cpu": command("sysctl", "-n", "machdep.cpu.brand_string"),
                 "memory_bytes": int(command("sysctl", "-n", "hw.memsize"))},
        "build": {"configuration": "release", "swift": command("swift", "--version"),
                  "xcode": command("xcodebuild", "-version"),
                  "sdk": command("xcrun", "--sdk", "macosx", "--show-sdk-version"),
                  "revision": command("git", "rev-parse", "HEAD"),
                  "worktree_dirty": bool(command("git", "status", "--porcelain")),
                  "source_sha256": source_hash.hexdigest(), "binary_sha256": digest(binary),
                  "instrumented_binary_sha256": digest(instrumented),
                  "measurement_script_sha256": digest(__file__),
                  "allocation_probe_sha256": digest(ROOT / "Benchmarks/Swsh/AllocationProbe.c"),
                  "allocation_counter_sha256": digest(ROOT / "Sources/CAllocCounter/CAllocCounter.c"),
                  "allocation_probe_flags": ["-O3", "-mmacosx-version-min=27.0", "-dynamiclib"],
                  "dependencies": json.loads((ROOT / "Package.resolved").read_text())},
        "method": [
            "Two warmups precede each wall-time workload; samples are warm-cache spawn-to-exit latency, not cold startup.",
            "Interactive startup includes Python PTY/home-directory fixture setup, ending at the first prompt.",
            "Latency and throughput use an uninstrumented release build and include Python pipe transfer/verification overhead.",
            "Allocation/RSS runs use a separate linked measurement library; timing from that build is not reported.",
            "Allocations count malloc allocation events from constructor to destructor, separately on the initial thread and across all threads (including the session executor); pre-constructor and post-destructor allocations are excluded.",
            "RSS is Darwin getrusage(RUSAGE_SELF).ru_maxrss in bytes, separately for each shell process; it is not summed concurrent tree memory.",
            "Private worker startup uses an exact-build, prewritten unlinked payload; it excludes payload creation but includes process startup, decoding and builtin execution.",
            "Worker overhead estimates subtract median empty invocation from median multi-command latency; parsing, payload I/O, pipes and reaping remain included.",
            "These are local observations, not regression thresholds or evidence of an ownership-feature speedup."
        ],
        "timing": {}, "instrumentation": {}
    }
    workloads = {
        "startup": (":", 0),
        "parent_builtins_1000": (" :;" * 1000, 0),
        "builtin_workers_100": (" : | :;" * 50, 100),
        "redirect_helpers_50": (" : >/dev/null;" * 50, 50),
        "function_calls_1000": ("f() { :; };" + " f;" * 1000, 0),
        "subshells_20": (" (:);" * 20, 20),
        "substitutions_20": (" x=$(true);" * 20, 20),
        "external_commands_100": (" /usr/bin/true;" * 100, 0),
    }
    for name, (source, workers) in workloads.items():
        print(f"Measuring {name}", file=sys.stderr, flush=True)
        result["timing"][name] = timed(binary, source, args.samples)
        if name != "external_commands_100":
            result["instrumentation"][name] = allocations(instrumented, source, workers)
    startup = result["timing"]["startup"]["summary_ns"]["median"]
    for name, count in (("parent_builtins_1000", 1000), ("builtin_workers_100", 100),
                        ("redirect_helpers_50", 50), ("external_commands_100", 100),
                        ("function_calls_1000", 1000), ("subshells_20", 20), ("substitutions_20", 20)):
        result["timing"][name]["amortized_incremental_ns_per_operation"] = (
            result["timing"][name]["summary_ns"]["median"] - startup) / count
    worker_payload = json.dumps({
        "kind": "builtin", "build": digest(binary), "executable": list(os.fsencode(binary)),
        "arguments": [[58]], "environment": [], "redirects": [],
        "builtinContext": {"builtin": ":", "variables": {}, "exported": [],
                           "status": 0, "opaqueEnvironment": []}
    }, separators=(",", ":")).encode()
    with tempfile.TemporaryFile() as payload:
        payload.write(b"SWSH0001" + len(worker_payload).to_bytes(8, "little") + worker_payload)
        payload.flush()
        result["timing"]["private_worker_startup"] = timed(binary, "", args.samples, payload=payload)
        result["timing"]["private_worker_startup"]["payload_bytes"] = len(worker_payload) + 16
    interactive = []
    for index in range(args.samples + 2):
        started = time.perf_counter_ns()
        with PtyShell(str(binary)) as shell:
            elapsed = time.perf_counter_ns() - started
            shell.send("exit\n")
            if shell.wait() != 0:
                raise RuntimeError("interactive startup/exit failed")
        if index >= 2:
            interactive.append(elapsed)
    result["timing"]["interactive_startup"] = {"wall_ns": interactive, "summary_ns": summarize(interactive)}
    size = 16 * 1024 * 1024
    data = bytes(range(256)) * (size // 256)
    streams = {
        "binary_pipeline_16MiB": timed(binary, "/bin/cat | /bin/cat | /bin/cat", args.samples, data, data),
        "stderr_16MiB": timed(binary, "/bin/sh -c 'dd if=/dev/zero bs=1048576 count=16 1>&2 2>/dev/null'",
                               args.samples, expected_stderr=bytes(size))
    }
    for name, sample in streams.items():
        sample["bytes"] = size
        sample["median_MiB_per_second"] = 16 * 1e9 / sample["summary_ns"]["median"]
        result["timing"][name] = sample
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(args.output)


if __name__ == "__main__":
    main()
