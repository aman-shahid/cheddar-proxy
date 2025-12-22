#!/usr/bin/env python3
"""
Generic process memory/CPU sampler with optional proxy load generation.

- Monitors RSS (and macOS footprint when available) over time.
- Works for any app: pass --process-name or --pid.
- Optional HTTP load through a proxy to exercise the app.

Requirements:
    pip3 install psutil requests

Usage examples:
    # Sample Cheddar Proxy on macOS for 2 minutes
    python3 scripts/benchmark/benchmark_process_metrics.py --process-name "Cheddar Proxy" --duration 120

    # Sample HTTP Toolkit on Windows while generating load through proxy port 8899
    python3 scripts/benchmark/benchmark_process_metrics.py --process-name "HTTP Toolkit" --duration 600 --with-load --proxy-port 8899
"""

import argparse
import os
import subprocess
import sys
import time
from datetime import datetime
from typing import Optional

try:
    import psutil
except ImportError:
    print("Error: psutil not installed. Run: pip3 install psutil")
    sys.exit(1)


def find_processes(pattern: str) -> list[psutil.Process]:
    """Find all processes whose name or executable basename contains the pattern (case-insensitive).

    Note: intentionally ignores full cmdline substrings to avoid spurious matches
    (e.g., shells or crashpad handlers launched with paths containing the pattern).
    """
    pattern_l = pattern.lower()
    matches = []
    for proc in psutil.process_iter(["pid", "name", "exe"]):
        try:
            name = (proc.info["name"] or "").lower()
            exe = (proc.info["exe"] or "").lower()
            exe_base = os.path.basename(exe) if exe else ""
            if pattern_l and (pattern_l in name or pattern_l in exe_base):
                matches.append(proc)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return matches


def format_bytes(val: float) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    for unit in units:
        if val < 1024.0:
            return f"{val:.1f} {unit}"
        val /= 1024.0
    return f"{val:.1f} PB"


def get_macos_footprint(pid: int) -> Optional[int]:
    """Return footprint bytes on macOS using the footprint tool."""
    try:
        result = subprocess.run(
            ["footprint", str(pid)],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return None
        for line in result.stdout.splitlines():
            if "Footprint:" in line:
                import re
                m = re.search(r"Footprint:\s*([\d.]+)\s*(KB|MB|GB)", line)
                if not m:
                    continue
                val = float(m.group(1))
                unit = m.group(2)
                if unit == "GB":
                    return int(val * 1024 * 1024 * 1024)
                if unit == "MB":
                    return int(val * 1024 * 1024)
                if unit == "KB":
                    return int(val * 1024)
        return None
    except Exception:
        return None


def measure(proc: psutil.Process) -> Optional[dict]:
    """Return memory/CPU stats for a process."""
    try:
        mem_info = proc.memory_info()
        cpu = proc.cpu_percent(interval=None)
        footprint = None
        if sys.platform == "darwin":
            footprint = get_macos_footprint(proc.pid)
        return {
            "rss": mem_info.rss,
            "footprint": footprint or mem_info.rss,
            "cpu": cpu,
        }
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return None


def generate_load(proxy_host: str, proxy_port: int, num_requests: int):
    """Simple HTTP load generator through a proxy."""
    try:
        import requests
    except ImportError:
        print("Warning: requests not installed; skipping load generation.")
        return

    proxies = {
        "http": f"http://{proxy_host}:{proxy_port}",
        "https": f"http://{proxy_host}:{proxy_port}",
    }
    urls = [
        "http://httpbin.org/get",
        "http://httpbin.org/headers",
        "http://httpbin.org/ip",
    ]
    print(f"Generating {num_requests} requests through proxy {proxy_host}:{proxy_port} ...")
    for i in range(num_requests):
        url = urls[i % len(urls)]
        try:
            requests.get(url, proxies=proxies, timeout=10)
        except Exception as e:
            print(f"  Request {i+1} failed: {e}")
        if (i + 1) % 100 == 0:
            print(f"  Completed {i + 1}/{num_requests}")
    print("Load generation complete.")


def main():
    parser = argparse.ArgumentParser(description="Process memory/CPU sampler")
    g = parser.add_mutually_exclusive_group(required=True)
    g.add_argument("--process-name", help="Process name/pattern to match")
    g.add_argument(
        "--pid",
        type=int,
        nargs="+",
        help="One or more PIDs to sample (sums memory/CPU across them)",
    )

    parser.add_argument("--duration", type=int, default=120, help="Duration in seconds (default: 120)")
    parser.add_argument("--interval", type=float, default=5.0, help="Sampling interval seconds (default: 5)")
    parser.add_argument("--with-load", action="store_true", help="Generate HTTP load via proxy")
    parser.add_argument("--requests", type=int, default=2000, help="Number of requests to generate when --with-load")
    parser.add_argument("--proxy-host", default="127.0.0.1", help="Proxy host for load generation")
    parser.add_argument("--proxy-port", type=int, default=9090, help="Proxy port for load generation")
    args = parser.parse_args()

    procs: list[psutil.Process] = []
    if args.pid:
        for pid in args.pid:
            try:
                procs.append(psutil.Process(pid))
            except psutil.NoSuchProcess:
                print(f"PID {pid} not found.")
                sys.exit(1)
    else:
        matches = find_processes(args.process_name)
        if not matches:
            print(f"No process matching '{args.process_name}' found.")
            sys.exit(1)
        procs.extend(matches)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    results_dir = os.path.join(script_dir, "..", "benchmark_results")
    os.makedirs(results_dir, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    raw_label = args.process_name or f"pid{'-'.join(str(p.pid) for p in procs)}"
    # Sanitize for filenames: replace spaces and path separators
    safe_label = (
        raw_label.replace(" ", "_")
        .replace("/", "_")
        .replace("\\", "_")
        .replace(":", "_")
    )
    outfile = os.path.join(results_dir, f"metrics_{safe_label}_{timestamp}.txt")

    class Tee:
        def __init__(self, *files):
            self.files = files
        def write(self, obj):
            for f in self.files:
                try:
                    f.write(obj)
                    f.flush()
                except ValueError:
                    # Ignore writes to closed files during interpreter shutdown
                    pass
        def flush(self):
            for f in self.files:
                try:
                    f.flush()
                except ValueError:
                    pass

    log = open(outfile, "w")
    original_stdout = sys.stdout
    sys.stdout = Tee(original_stdout, log)

    print(f"Results will be saved to: {outfile}")
    if len(procs) == 1:
        p = procs[0]
        print(f"Monitoring PID {p.pid} ({p.name()}) for {args.duration}s, interval={args.interval}s")
    else:
        ids = ", ".join(f"{p.pid} ({p.name()})" for p in procs)
        print(f"Monitoring PIDs [{ids}] for {args.duration}s, interval={args.interval}s (aggregated)")
    print(f"Platform: {sys.platform}")
    print()

    measurements = []
    start = time.time()

    # Prime CPU percent to get non-zero values on first sample
    for p in procs:
        p.cpu_percent(interval=None)

    # Optional load in background
    load_thread = None
    if args.with_load:
        import threading

        load_thread = threading.Thread(
            target=generate_load,
            args=(args.proxy_host, args.proxy_port, args.requests),
            daemon=True,
        )
        load_thread.start()

    print("Time (s) | RSS        | Footprint  | CPU%")
    print("-------------------------------------------")
    while time.time() - start < args.duration:
        agg = {"rss": 0, "footprint": 0, "cpu": 0.0}
        alive = False
        for p in procs:
            m = measure(p)
            if not m:
                continue
            alive = True
            agg["rss"] += m["rss"]
            agg["footprint"] += m["footprint"]
            agg["cpu"] += m["cpu"]
        if not alive:
            print("Processes exited.")
            break
        elapsed = time.time() - start
        print(
            f"{elapsed:7.1f} | {format_bytes(agg['rss']):10} | "
            f"{format_bytes(agg['footprint']):10} | {agg['cpu']:4.1f}"
        )
        measurements.append(agg)
        time.sleep(args.interval)

    if load_thread:
        load_thread.join()

    if measurements:
        rss_vals = [m["rss"] for m in measurements]
        foot_vals = [m["footprint"] for m in measurements]
        cpu_vals = [m["cpu"] for m in measurements]
        print("\nSummary:")
        print(f"  RSS: min={format_bytes(min(rss_vals))}, max={format_bytes(max(rss_vals))}")
        print(f"  Footprint: min={format_bytes(min(foot_vals))}, max={format_bytes(max(foot_vals))}")
        print(f"  CPU: min={min(cpu_vals):.1f}%, max={max(cpu_vals):.1f}%")

    # Restore stdout before closing file to avoid flush-on-exit errors
    sys.stdout = original_stdout
    log.close()


if __name__ == "__main__":
    main()
