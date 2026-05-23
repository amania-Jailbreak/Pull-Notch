#!/usr/bin/env python3
"""Run gamdl for each Apple Music URL in a JSON file with overall progress output."""

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


def extract_urls(payload: Any) -> list[str]:
    """Extract URLs from known JSON shapes."""
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, str)]

    if isinstance(payload, dict):
        for key in ("urls", "tracks", "items"):
            value = payload.get(key)
            if isinstance(value, list):
                return [item for item in value if isinstance(item, str)]

    return []


def format_duration(seconds: float) -> str:
    total = int(seconds)
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h:02d}:{m:02d}:{s:02d}"
    return f"{m:02d}:{s:02d}"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run gamdl for each URL in a JSON file with progress."
    )
    parser.add_argument(
        "json_file",
        nargs="?",
        default="track_ids.json",
        help="Path to JSON file containing URL list (default: track_ids.json)",
    )
    parser.add_argument(
        "--lang",
        default="ja-jp",
        help="Language code passed to gamdl -l (default: ja-jp)",
    )
    parser.add_argument(
        "--stop-on-error",
        action="store_true",
        help="Stop immediately when one URL fails.",
    )
    args = parser.parse_args()

    json_path = Path(args.json_file)
    if not json_path.exists():
        print(f"Error: JSON file not found: {json_path}", file=sys.stderr)
        return 1

    try:
        payload = json.loads(json_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"Error: Failed to parse JSON: {exc}", file=sys.stderr)
        return 1

    urls = extract_urls(payload)
    if not urls:
        print("Error: No URLs found in JSON.", file=sys.stderr)
        return 1

    total = len(urls)
    failures: list[tuple[str, int]] = []
    started = time.time()

    print(f"Found {total} URLs in {json_path}")

    for index, url in enumerate(urls, start=1):
        completed_before = index - 1
        percent_before = (completed_before / total) * 100
        elapsed = time.time() - started
        print(
            f"\n[{index}/{total}] {percent_before:6.2f}% elapsed={format_duration(elapsed)}"
        )
        print(f"URL: {url}")

        cmd = ["gamdl", "-l", args.lang, url]
        print(f"Run: {shlex.join(cmd)}")

        result = subprocess.run(cmd)
        if result.returncode != 0:
            failures.append((url, result.returncode))
            print(f"Status: FAILED (exit={result.returncode})")
            if args.stop_on_error:
                break
        else:
            print("Status: OK")

    elapsed_total = time.time() - started
    done = total - len(failures)
    print("\n========== Summary ==========")
    print(f"Total:   {total}")
    print(f"Success: {done}")
    print(f"Failed:  {len(failures)}")
    print(f"Elapsed: {format_duration(elapsed_total)}")

    if failures:
        print("\nFailed URLs:")
        for failed_url, code in failures:
            print(f"- exit={code} {failed_url}")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
