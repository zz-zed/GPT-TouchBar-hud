"""Bound the native menu test independently of AppKit's main event loop."""
import argparse
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout-seconds", type=float, default=60)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command or args.timeout_seconds <= 0:
        parser.error("a command and positive timeout are required")
    try:
        result = subprocess.run(args.command, timeout=args.timeout_seconds, check=False)
        return result.returncode if result.returncode >= 0 else 128 - result.returncode
    except subprocess.TimeoutExpired:
        print(f"Status menu test exceeded {args.timeout_seconds:g}s; test failed (no checks skipped)",
              file=sys.stderr, flush=True)
        return 124


if __name__ == "__main__":
    sys.exit(main())
