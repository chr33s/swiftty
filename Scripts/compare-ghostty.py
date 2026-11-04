#!/usr/bin/env python3
"""Compare `swiftty-bench stream` with `ghostty-bench +terminal-stream`.

<ghostty-src> must be built with
  zig build -Demit-bench -Doptimize=ReleaseFast -Demit-macos-app=false

Rounds follow a Williams design, so each variant runs in every position and
after every other variant equally often. CPU time (user + sys) is the default
metric, as it varies less with machine load; wall time is also recorded.
Ghostty raises its 10,000-byte scrollback to two 215-row pages;
"swiftty-matched" gets the same history.

`--generate` also writes kitty's `kitten __benchmark__` payloads, built from its
source at a pinned commit (downloaded, not vendored). Images are omitted:
Swiftty ignores APC strings, so it would skip all of Ghostty's image work.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
MIB = 1 << 20
CELL_STRIDE = 16  # MemoryLayout<Cell>.stride
GHOSTTY_PAGE_ROWS = 215  # page.zig std_capacity (cols <= 215)

SWIFTTY_INPUTS = [
    "ascii", "utf8", "utf8-cjk", "utf8-latin", "compiler-log", "cat-source",
    "csi-heavy", "osc-heavy", "scroll", "unicode-joins",
]
KITTY_COMMIT = "fb9933810113624d122eda2ce1676e5cd09f63c1"
KITTY_SOURCE_SHA256 = "ab178c9911ab03c39fcc22e85cd37c88d5ae3c5555d56ba9eb90ed494b6672a0"
KITTY_URL = f"https://raw.githubusercontent.com/kovidgoyal/kitty/{KITTY_COMMIT}/tools/cmd/benchmark/main.go"
KITTY_INPUTS = ["kitty-ascii", "kitty-unicode", "kitty-unique-unicode", "kitty-csi", "kitty-long-escape-codes"]
GHOSTTY_INPUTS = {
    "ghostty-ascii": ["+ascii"],
    "ghostty-osc": ["+osc"],  # unseeded
    "ghostty-styled": ["+styled", "--seed=42", "--style-rate=0.3"],
    "ghostty-utf8": ["+utf8", "--seed=42"],
}


def output(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(MIB):
            h.update(chunk)
    return h.hexdigest()


def generate(corpus, swiftty, ghostty_gen, megabytes):
    corpus.mkdir(parents=True, exist_ok=True)
    for name in SWIFTTY_INPUTS:
        with open(corpus / f"{name}.bin", "wb") as f:
            subprocess.run([swiftty, "gen", name, "--mb", str(megabytes)], stdout=f, check=True)
    for name, args in GHOSTTY_INPUTS.items():
        want = megabytes * MIB
        proc = subprocess.Popen([ghostty_gen, *args], stdout=subprocess.PIPE)
        with open(corpus / f"{name}.bin", "wb") as f:
            while want > 0:
                chunk = proc.stdout.read(min(want, MIB))
                if not chunk:
                    sys.exit(f"ghostty-gen {args[0]} ended early")
                f.write(chunk)
                want -= len(chunk)
        proc.kill()
        proc.wait()


def kitty_constants(corpus):
    path = corpus / "kitty-benchmark-main.go"
    if not path.exists():
        with urllib.request.urlopen(KITTY_URL) as response:
            path.write_bytes(response.read())
    if hashlib.sha256(path.read_bytes()).hexdigest() != KITTY_SOURCE_SHA256:
        sys.exit(f"{path} does not match kitty {KITTY_COMMIT[:10]}")
    text = path.read_text()
    literal = r'"(?:[^"\\]|\\.)*"'
    consts = {}
    for name in ("reset", "ascii_printable", "control_chars", "chinese_lorem_ipsum", "misc_unicode"):
        m = re.search(rf"^const {name} = ((?:{literal}(?:\s*\+\s*)?)+)", text, re.M)
        parts = re.findall(literal, m.group(1))
        consts[name] = "".join(json.loads(re.sub(r"\\x([0-9a-fA-F]{2})", r"\\u00\1", p)) for p in parts)
    return consts


def kitty_payloads(k, rng):
    """kitty's benchmark data, with Go's unseeded RNG replaced by `rng`."""
    def random_string(n, alphabet):
        return "".join(rng.choices(alphabet, k=n))
    controls = k["control_chars"]
    unique = []
    for i in range(256 * 1024):
        q = i
        unique.append("a")
        for _ in range(3):
            unique.append(chr(0x300 + q % 0x70))
            q //= 0x70
    csi = []
    size = 0
    while size < 1024 * 1024 + 17:
        q = rng.randrange(100)
        if q < 10:
            chunk = random_string(rng.randrange(72) + 1, k["ascii_printable"] + controls)
        elif q < 30:
            chunk = "\x1b[m\x1b[?1h\x1b[H"
        elif q < 40:
            chunk = "\x1b[1;2;3;4:3;31m"
        elif q < 50:
            chunk = "\x1b[38:5:24;48:2:125:136:147m"
        elif q < 60:
            chunk = "\x1b[58;5;44;2m"
        elif q < 80:
            chunk = "\x1b[m\x1b[10A\x1b[3E\x1b[2K"
        else:
            chunk = "\x1b[39m\x1b[10`a\x1b[100b\x1b[?1l"
        csi.append(chunk)
        size += len(chunk)
    csi.append("\x1b[m")
    return {
        "kitty-ascii": ("Only ASCII chars", random_string(1024 * 2048 + 13, k["ascii_printable"] + controls)),
        "kitty-unicode": ("Unicode chars", (k["chinese_lorem_ipsum"] + k["misc_unicode"] + controls) * 1024),
        "kitty-unique-unicode": ("Unique multi-codepoint Unicode cells", "".join(unique)),
        "kitty-csi": ("CSI codes with few chars", "".join(csi)),
        "kitty-long-escape-codes": ("Long escape codes",
                                    ("\x1b]6;" + random_string(8024, k["ascii_printable"]) + "\x07") * 1024),
    }


def generate_kitty(corpus, megabytes, seed):
    """Repeats each payload as the kitten does: alternate screen, rendering
    paused, the description redrawn between repetitions, status queries last."""
    k = kitty_constants(corpus)
    clear = "\x1b[m\x1b[H\x1b[2J"
    pause, resume = "\x1b[?2026h", "\x1b[?2026l"
    for name, (description, data) in kitty_payloads(k, random.Random(seed)).items():
        data = data.encode()
        desc = (clear + "Running: " + description + "\r\n").encode()
        between = desc + resume.encode() + pause.encode()
        reps = max(1, -(-megabytes * MIB // (len(data) + len(between))))
        with open(corpus / f"{name}.bin", "wb") as f:
            f.write(b"\x1b7\x1b[?1049h\x1b[H\x1b[2J\x1b[?25l" + desc + pause.encode())
            for _ in range(reps):
                f.write(data)
                f.write(between)
            f.write((clear + "Waiting for response indicating parsing finished\r\n" + resume
                     + "\x1b[6n" + "\x1b[5n" * 3 + "\x1b[?1049l" + k["reset"]).encode())


def williams(n):
    """Orders in which each of n variants precedes every other equally often."""
    base, lo, hi = [0], 1, n - 1
    for i in range(1, n):
        if i % 2:
            base.append(lo)
            lo += 1
        else:
            base.append(hi)
            hi -= 1
    rows = [[(b + r) % n for b in base] for r in range(n)]
    return rows + [row[::-1] for row in rows] if n % 2 else rows


def run_once(cmd):
    """Wall and CPU seconds, peak RSS (MiB)."""
    # A stderr pipe would fill on Ghostty's logs and deadlock wait4.
    with tempfile.TemporaryFile() as err:
        start = time.perf_counter_ns()
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=err)
        _, status, usage = os.wait4(proc.pid, 0)
        elapsed = (time.perf_counter_ns() - start) / 1e9
        proc.returncode = os.waitstatus_to_exitcode(status)
        if proc.returncode != 0:
            err.seek(0)
            sys.exit(f"{cmd[0]} exited {proc.returncode}: {err.read()[-4096:].decode(errors='replace')}")
    rss = usage.ru_maxrss / MIB if sys.platform == "darwin" else usage.ru_maxrss / 1024
    return elapsed, usage.ru_utime + usage.ru_stime, rss


def bootstrap_ratio(base, other, rng, iterations=4000):
    """Paired 95% interval for median(base) / median(other)."""
    n = len(base)
    ratios = []
    for _ in range(iterations):
        idx = [rng.randrange(n) for _ in range(n)]
        ratios.append(statistics.median(base[i] for i in idx) / statistics.median(other[i] for i in idx))
    ratios.sort()
    return ratios[int(0.025 * iterations)], ratios[int(0.975 * iterations) - 1]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ghostty_src", type=Path)
    ap.add_argument("corpus", type=Path)
    ap.add_argument("--generate", action="store_true", help="(re)generate the corpus first")
    ap.add_argument("--mb", type=int, default=100, help="input size when generating")
    ap.add_argument("--runs", type=int, default=20)
    ap.add_argument("--warmup", type=int, default=2)
    ap.add_argument("--cols", type=int, default=120)
    ap.add_argument("--rows", type=int, default=80)
    ap.add_argument("--only", help="comma-separated input names")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--metric", choices=("cpu", "wall"), default="cpu", help="headline metric")
    ap.add_argument("--no-kitty", action="store_true", help="skip kitty's payloads")
    ap.add_argument("--ghostty-quiet", type=Path,
                    help="checkout built with log_level = .err in main_bench.zig")
    ap.add_argument("--zig", default="zig", help="zig that built ghostty-bench (metadata)")
    ap.add_argument("--output", type=Path, help="raw JSON (default <corpus>/results.json)")
    args = ap.parse_args()

    if args.cols > GHOSTTY_PAGE_ROWS or args.rows >= 2 * GHOSTTY_PAGE_ROWS:
        sys.exit("matched-history estimate assumes cols <= 215 and rows < 430")
    ghostty = args.ghostty_src / "zig-out/bin/ghostty-bench"
    ghostty_gen = args.ghostty_src / "zig-out/bin/ghostty-gen"
    swiftty = ROOT / ".build/release/swiftty-bench"
    for exe in (ghostty, ghostty_gen, swiftty):
        if not exe.exists():
            sys.exit(f"missing {exe}")
    kitty = [] if args.no_kitty else KITTY_INPUTS
    if args.generate:
        generate(args.corpus, swiftty, ghostty_gen, args.mb)
        if kitty:
            generate_kitty(args.corpus, args.mb, args.seed)

    names = [n for n in SWIFTTY_INPUTS + list(GHOSTTY_INPUTS) + kitty
             if not args.only or n in args.only.split(",")]
    missing = [n for n in names if not (args.corpus / f"{n}.bin").exists()]
    if missing:
        sys.exit(f"missing inputs {missing}; pass --generate")

    history_rows = 2 * GHOSTTY_PAGE_ROWS - args.rows
    matched_bytes = history_rows * args.cols * CELL_STRIDE
    size = [f"--terminal-cols={args.cols}", f"--terminal-rows={args.rows}"]
    variants = {
        "ghostty": lambda d: [str(ghostty), "+terminal-stream", f"--data={d}", *size],
        "swiftty": lambda d: [str(swiftty), "stream", f"--data={d}", *size, "--scrollback-bytes=10000"],
        "swiftty-matched": lambda d: [str(swiftty), "stream", f"--data={d}", *size,
                                      f"--scrollback-bytes={matched_bytes}"],
    }

    if args.ghostty_quiet:
        quiet = args.ghostty_quiet / "zig-out/bin/ghostty-bench"
        if not quiet.exists():
            sys.exit(f"missing {quiet}")
        variants["ghostty-quiet"] = lambda d: [str(quiet), "+terminal-stream", f"--data={d}", *size]

    rng = random.Random(args.seed)
    orders = williams(len(variants))
    if args.runs % len(orders):
        print(f"note: --runs {args.runs} is not a multiple of {len(orders)}; order balance is partial",
              file=sys.stderr)
    results = {}
    for name in names:
        data = args.corpus / f"{name}.bin"
        cmds = {v: make(data) for v, make in variants.items()}
        for _ in range(args.warmup):
            for cmd in cmds.values():
                run_once(cmd)
        load = os.getloadavg()[0]
        keys = list(cmds)
        rng.shuffle(keys)  # which variant takes which design slot
        samples = {v: {"wall_s": [], "cpu_s": [], "peak_rss_mib": [], "position": []} for v in cmds}
        for r in range(args.runs):
            for pos, slot in enumerate(orders[r % len(orders)]):
                v = keys[slot]
                wall, cpu, rss = run_once(cmds[v])
                samples[v]["wall_s"].append(wall)
                samples[v]["cpu_s"].append(cpu)
                samples[v]["peak_rss_mib"].append(rss)
                samples[v]["position"].append(pos)
        summary = {}
        for v, s in samples.items():
            entry = {"median_peak_rss_mib": statistics.median(s["peak_rss_mib"])}
            for metric in ("cpu", "wall"):
                values, base = s[f"{metric}_s"], samples["ghostty"][f"{metric}_s"]
                m = {"median_ms": statistics.median(values) * 1000}
                if v != "ghostty":
                    m["relative_throughput"] = statistics.median(base) / statistics.median(values)
                    m["relative_ci95"] = list(bootstrap_ratio(base, values, rng))
                entry[metric] = m
            entry.update(entry[args.metric])
            summary[v] = entry
        results[name] = {"bytes": data.stat().st_size, "sha256": sha256(data),
                         "load_avg_1m": [load, os.getloadavg()[0]],
                         "samples": samples, "summary": summary}
        line = f"{name:24} ghostty {summary['ghostty']['median_ms']:8.1f} ms"
        for v, e in summary.items():
            if v != "ghostty":
                lo, hi = e["relative_ci95"]
                line += f"  {v} {e['median_ms']:8.1f} ms {e['relative_throughput']:6.1%} [{lo:.1%}, {hi:.1%}]"
        print(line, flush=True)

    meta = {
        "date": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "host": {
            "cpu": output("sysctl", "-n", "machdep.cpu.brand_string") if sys.platform == "darwin" else platform.processor(),
            "cores": os.cpu_count(),
            "memory_bytes": int(output("sysctl", "-n", "hw.memsize")) if sys.platform == "darwin" else None,
            "os": platform.platform(),
        },
        "swiftty": {"revision": output("git", "rev-parse", "HEAD", cwd=ROOT),
                    "dirty": bool(output("git", "status", "--porcelain", cwd=ROOT)),
                    "swift": output("swift", "--version").splitlines()[0],
                    "binary_sha256": sha256(swiftty)},
        "ghostty": {"revision": output("git", "rev-parse", "HEAD", cwd=args.ghostty_src),
                    "zig": output(args.zig, "version"),
                    "binary_sha256": sha256(ghostty),
                    "quiet_binary_sha256": sha256(quiet) if args.ghostty_quiet else None},
        "cols": args.cols, "rows": args.rows, "runs": args.runs, "warmup": args.warmup,
        "seed": args.seed, "chunk_bytes": 65536, "metric": args.metric,
        "order_design": "williams", "kitty_commit": KITTY_COMMIT if kitty else None,
        "swiftty_scrollback_bytes": {"swiftty": 10000, "swiftty-matched": matched_bytes},
        "matched_history_rows": history_rows,
    }
    out = args.output or args.corpus / "results.json"
    out.write_text(json.dumps({"meta": meta, "results": results}, indent=1) + "\n")
    print(f"wrote {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
