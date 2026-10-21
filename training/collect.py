#!/usr/bin/env python3
"""Collect training examples: run practice requests through Halo, keep real successes.

    python3 -I training/collect.py                      # every practice task once
    python3 -I training/collect.py --limit 50           # the 50 least-collected tasks
    python3 -I training/collect.py --only browser,files # categories or task ids
    python3 -I training/collect.py --accounts           # also Gmail, LinkedIn, GitHub tasks

Uses the same setups and outcome checks as run_eval.py. Halo records into a
temporary folder; a recording is copied into the training folder
(~/Library/Application Support/Halo/Traces) only when every check passed, no
forbidden tool ran, and the answer neither asks permission nor claims a
success the checks contradict. Tasks run least-collected first, tracked in
~/Library/Application Support/Halo/Collect/counts.json, so repeated nights
spread across the list. Recordings that mention a held-out exam site are
dropped. Leave the Mac alone while it runs.
"""

import argparse
import json
import os
import shutil
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import practice_tasks  # noqa: E402
import run_eval  # noqa: E402

TRAINING = os.path.expanduser("~/Library/Application Support/Halo/Traces")
HELD_OUT = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "eval_tasks.json")))["held_out_sites"]
STATE = os.path.expanduser("~/Library/Application Support/Halo/Collect")


def keep(trace_dir, line, result):
    """Copy one recording and the tool list and instructions it refers to."""
    trace = json.loads(line)
    os.makedirs(os.path.join(TRAINING, "blobs"), exist_ok=True)
    for digest, ext in ((trace.get("tools"), "json"), (trace.get("instructions"), "txt")):
        if digest:
            source = os.path.join(trace_dir, "blobs", f"{digest}.{ext}")
            target = os.path.join(TRAINING, "blobs", f"{digest}.{ext}")
            if os.path.exists(source) and not os.path.exists(target):
                shutil.copy(source, target)
    day = trace["date"][:10]
    with open(os.path.join(TRAINING, f"{day}.jsonl"), "a", encoding="utf-8") as handle:
        handle.write(line if line.endswith("\n") else line + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--only", default="", help="comma-separated task ids or categories")
    parser.add_argument("--limit", type=int, default=0, help="run at most this many tasks")
    parser.add_argument("--accounts", action="store_true", help="include tasks that read signed-in accounts or open Gmail drafts")
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    tasks = [t for t in practice_tasks.generate() if args.accounts or not t["accounts"]]
    if args.only:
        wanted = {w.strip() for w in args.only.split(",")}
        tasks = [t for t in tasks if t["id"] in wanted or t["category"] in wanted]
    os.makedirs(STATE, exist_ok=True)
    counts_path = os.path.join(STATE, "counts.json")
    counts = json.load(open(counts_path)) if os.path.exists(counts_path) else {}
    tasks.sort(key=lambda t: (counts.get(t["prompt"], {}).get("kept", 0), counts.get(t["prompt"], {}).get("runs", 0)))
    if args.limit:
        tasks = tasks[:args.limit]

    stamp = datetime.now().strftime("%Y-%m-%d-%H%M")
    trace_dir = os.path.join(STATE, stamp, "traces")
    os.makedirs(trace_dir, exist_ok=True)
    volume = run_eval.osascript("output volume of (get volume settings)")
    kept = 0
    try:
        run_eval.launch(trace_dir)
        for task in tasks:
            before = len(run_eval.trace_lines(trace_dir))
            result = run_eval.run_task(task, trace_dir, args.timeout)
            lines = run_eval.trace_lines(trace_dir)
            good = result["passed"] and len(lines) > before and json.loads(lines[before])["brain"] != "shortcut"
            # A practice run can still pass through a held-out site (a search result,
            # say); such a recording would leak the exam, so it is dropped.
            leaked = good and [site for site in HELD_OUT if site in lines[before].lower()]
            if leaked:
                good = False
                result["result"] = "held-out"
            if good:
                keep(trace_dir, lines[before], result)
                kept += 1
            entry = counts.setdefault(task["prompt"], {"runs": 0, "kept": 0})
            entry["runs"] += 1
            entry["kept"] += int(good)
            with open(counts_path, "w") as handle:
                json.dump(counts, handle, indent=1, ensure_ascii=False)
            print(f"{task['id']:<20} {'kept' if good else result['result']:<12} {result['seconds']:>6} s", flush=True)
    finally:
        run_eval.osascript(f"set volume output volume {volume}")
    print(f"\nKept {kept} of {len(tasks)} recordings in {TRAINING}")


if __name__ == "__main__":
    main()
