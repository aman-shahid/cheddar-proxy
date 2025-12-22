#!/usr/bin/env python3
"""
Cheddar Proxy Memory Benchmark

Monitors memory usage of the Cheddar Proxy process over time,
optionally while generating load.

Requirements:
    pip3 install psutil requests

Usage:
    python3 benchmark_memory.py
    python3 benchmark_memory.py --with-load --requests 10000
"""

import argparse
import os
import subprocess
import sys
import time
from datetime import datetime

try:
    import psutil
except ImportError:
    print("Error: psutil not installed. Run: pip3 install psutil")
    sys.exit(1)


def find_cheddar_process():
    """Find the Cheddar Proxy process (the actual app, not build tools)."""
    candidates = []
    
    for proc in psutil.process_iter(['pid', 'name', 'cmdline', 'exe']):
        try:
            name = (proc.info['name'] or '').lower()
            cmdline = ' '.join(proc.info['cmdline'] or []).lower()
            exe = (proc.info['exe'] or '').lower()
            
            # Skip build/compilation tools
            if 'dartaotruntime' in cmdline or 'frontend_server' in cmdline:
                continue
            if 'dart-sdk' in exe:
                continue
            
            # Look for the actual app
            if 'cheddar proxy' in name or 'cheddar proxy.app' in cmdline:
                candidates.append((proc, 'app_name'))
            elif '/ui/' in exe and 'cheddar proxy' in exe.lower():
                candidates.append((proc, 'exe_path'))
            elif '/cheddar proxy.app/' in cmdline.lower():
                candidates.append((proc, 'cmdline_app'))
                
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    
    if candidates:
        # Prefer matches by app name
        for proc, match_type in candidates:
            if match_type == 'app_name':
                return proc
        return candidates[0][0]
    
    return None


def format_bytes(bytes_val):
    """Format bytes as human-readable string."""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if bytes_val < 1024:
            return f"{bytes_val:.1f} {unit}"
        bytes_val /= 1024
    return f"{bytes_val:.1f} TB"


def get_footprint(pid):
    """Get the memory footprint (what Activity Monitor shows) on macOS."""
    try:
        result = subprocess.run(
            ['footprint', str(pid)],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            # Parse: "Cheddar Proxy [69564]: 64-bit    Footprint: 335 MB"
            for line in result.stdout.split('\n'):
                if 'Footprint:' in line:
                    # Extract the number, e.g., "335 MB" or "1.2 GB"
                    import re
                    match = re.search(r'Footprint:\s*([\d.]+)\s*(MB|GB|KB)', line)
                    if match:
                        value = float(match.group(1))
                        unit = match.group(2)
                        if unit == 'GB':
                            return int(value * 1024 * 1024 * 1024)
                        elif unit == 'MB':
                            return int(value * 1024 * 1024)
                        elif unit == 'KB':
                            return int(value * 1024)
        return None
    except Exception:
        return None


def measure_memory(proc):
    """Get memory info for a process.
    
    On macOS, uses 'footprint' command to match Activity Monitor.
    Falls back to RSS on other platforms.
    """
    try:
        pid = proc.pid
        
        # On macOS, try to get footprint (matches Activity Monitor)
        if sys.platform == 'darwin':
            footprint = get_footprint(pid)
            if footprint:
                # Also get RSS for comparison
                mem_info = proc.memory_info()
                return {
                    'footprint': footprint,  # What Activity Monitor shows
                    'rss': mem_info.rss,      # Traditional RSS
                }
        
        # Fallback to RSS on other platforms
        mem_info = proc.memory_info()
        return {
            'footprint': mem_info.rss,  # Use RSS as footprint on non-macOS
            'rss': mem_info.rss,
        }
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return None


def generate_load(proxy_host, proxy_port, num_requests):
    """Generate HTTP requests through the proxy."""
    try:
        import requests
    except ImportError:
        print("Warning: requests not installed. Skipping load generation.")
        print("         Run: pip3 install requests")
        return
    
    proxies = {
        'http': f'http://{proxy_host}:{proxy_port}',
        'https': f'http://{proxy_host}:{proxy_port}',
    }
    
    urls = [
        'http://httpbin.org/get',
        'http://httpbin.org/headers',
        'http://httpbin.org/ip',
    ]
    
    print(f"\nGenerating {num_requests} requests through proxy...")
    
    for i in range(num_requests):
        url = urls[i % len(urls)]
        try:
            requests.get(url, proxies=proxies, timeout=10)
            if (i + 1) % 100 == 0:
                print(f"  Completed {i + 1}/{num_requests} requests")
        except Exception as e:
            print(f"  Request {i + 1} failed: {e}")
    
    print(f"Load generation complete: {num_requests} requests\n")


def run_benchmark(duration_seconds=60, interval=1, with_load=False, 
                  num_requests=1000, proxy_host='127.0.0.1', proxy_port=9090):
    """Run the memory benchmark."""
    
    print("╔══════════════════════════════════════════════════════════════╗")
    print("║           Cheddar Proxy Memory Benchmark                      ║")
    print("╚══════════════════════════════════════════════════════════════╝")
    print()
    
    # Find the process
    proc = find_cheddar_process()
    if proc is None:
        print("❌ Error: Cheddar Proxy process not found.")
        print("   Please start Cheddar Proxy first: ./scripts/run.sh")
        sys.exit(1)
    
    print(f"✓ Found Cheddar Proxy (PID: {proc.pid})")
    print(f"  Monitoring for {duration_seconds} seconds...")
    print()
    
    # Initial measurement
    initial_mem = measure_memory(proc)
    if initial_mem is None:
        print("❌ Error: Could not measure memory.")
        sys.exit(1)
    
    is_macos = 'footprint' in initial_mem and initial_mem['footprint'] != initial_mem['rss']
    
    print(f"Initial Memory:")
    if is_macos:
        print(f"  Footprint: {format_bytes(initial_mem['footprint'])}  ← Activity Monitor value")
        print(f"  RSS:       {format_bytes(initial_mem['rss'])}  (includes shared libs)")
    else:
        print(f"  RSS: {format_bytes(initial_mem['rss'])}")
    print()
    
    # Generate load in background if requested
    if with_load:
        import threading
        load_thread = threading.Thread(
            target=generate_load,
            args=(proxy_host, proxy_port, num_requests)
        )
        load_thread.start()
    
    # Collect measurements
    measurements = []
    start_time = time.time()
    
    if is_macos:
        print("Time       | Footprint  | RSS        | Δ Footprint")
    else:
        print("Time       | RSS        | Δ RSS")
    print("-" * 55)
    
    while time.time() - start_time < duration_seconds:
        mem = measure_memory(proc)
        if mem is None:
            print("Process ended.")
            break
        
        elapsed = time.time() - start_time
        
        if is_macos:
            delta = mem['footprint'] - initial_mem['footprint']
            delta_sign = '+' if delta >= 0 else '-'
            print(f"{elapsed:6.1f}s    | {format_bytes(mem['footprint']):10} | "
                  f"{format_bytes(mem['rss']):10} | {delta_sign}{format_bytes(abs(delta))}")
        else:
            delta = mem['rss'] - initial_mem['rss']
            delta_sign = '+' if delta >= 0 else '-'
            print(f"{elapsed:6.1f}s    | {format_bytes(mem['rss']):10} | {delta_sign}{format_bytes(abs(delta))}")
        
        measurements.append({
            'time': elapsed,
            'footprint': mem['footprint'],
            'rss': mem['rss'],
        })
        
        time.sleep(interval)
    
    # Wait for load thread if running
    if with_load:
        load_thread.join()
    
    # Summary
    print()
    print("═" * 55)
    print("Summary:")
    print("═" * 55)
    
    if measurements:
        footprint_values = [m['footprint'] for m in measurements]
        rss_values = [m['rss'] for m in measurements]
        
        if is_macos:
            print(f"  Initial Footprint:  {format_bytes(initial_mem['footprint'])}")
            print(f"  Final Footprint:    {format_bytes(footprint_values[-1])}")
            print(f"  Peak Footprint:     {format_bytes(max(footprint_values))}")
            print(f"  Min Footprint:      {format_bytes(min(footprint_values))}")
            delta = footprint_values[-1] - initial_mem['footprint']
            delta_sign = '+' if delta >= 0 else '-'
            print(f"  Δ Footprint:        {delta_sign}{format_bytes(abs(delta))}")
            print()
            print(f"  (RSS range: {format_bytes(min(rss_values))} - {format_bytes(max(rss_values))})")
        else:
            print(f"  Initial RSS:  {format_bytes(initial_mem['rss'])}")
            print(f"  Final RSS:    {format_bytes(rss_values[-1])}")
            print(f"  Peak RSS:     {format_bytes(max(rss_values))}")
            print(f"  Min RSS:      {format_bytes(min(rss_values))}")
            delta = rss_values[-1] - initial_mem['rss']
            delta_sign = '+' if delta >= 0 else '-'
            print(f"  Δ RSS:        {delta_sign}{format_bytes(abs(delta))}")
    
    print()
    print("Note: Footprint matches Activity Monitor 'Memory' column.")
    print("Benchmark complete!")


def main():
    parser = argparse.ArgumentParser(
        description='Cheddar Proxy Memory Benchmark'
    )
    parser.add_argument(
        '--duration', '-d', type=int, default=60,
        help='Duration in seconds (default: 60)'
    )
    parser.add_argument(
        '--interval', '-i', type=float, default=2,
        help='Measurement interval in seconds (default: 2)'
    )
    parser.add_argument(
        '--with-load', '-l', action='store_true',
        help='Generate HTTP load while measuring'
    )
    parser.add_argument(
        '--requests', '-r', type=int, default=1000,
        help='Number of requests to generate (with --with-load)'
    )
    parser.add_argument(
        '--proxy-host', default='127.0.0.1',
        help='Proxy host (default: 127.0.0.1)'
    )
    parser.add_argument(
        '--proxy-port', type=int, default=9090,
        help='Proxy port (default: 9090)'
    )
    
    args = parser.parse_args()
    
    # Set up output file
    script_dir = os.path.dirname(os.path.abspath(__file__))
    results_dir = os.path.join(script_dir, '..', 'benchmark_results')
    os.makedirs(results_dir, exist_ok=True)
    
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    output_file = os.path.join(results_dir, f'memory_{timestamp}.txt')
    
    # Redirect stdout to both console and file
    class Tee:
        def __init__(self, *files):
            self.files = files
        def write(self, obj):
            for f in self.files:
                f.write(obj)
                f.flush()
        def flush(self):
            for f in self.files:
                f.flush()
    
    log_file = open(output_file, 'w')
    sys.stdout = Tee(sys.__stdout__, log_file)
    
    print(f"Results will be saved to: {output_file}")
    print()
    
    run_benchmark(
        duration_seconds=args.duration,
        interval=args.interval,
        with_load=args.with_load,
        num_requests=args.requests,
        proxy_host=args.proxy_host,
        proxy_port=args.proxy_port,
    )
    
    log_file.close()


if __name__ == '__main__':
    main()
