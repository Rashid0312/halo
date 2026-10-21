#!/usr/bin/env python3
"""Turn Halo's recorded traces into mlx-lm training files.

    python3 -I training/export_traces.py --out data
    python3 -I training/export_traces.py --out data --test-domains wikipedia.org,bbc.com

Reads ~/Library/Application Support/Halo/Traces (Settings → Privacy → Training
data) and writes train.jsonl, valid.jsonl, and test.jsonl in mlx-lm's
{"messages", "tools"} format.

Each recorded turn becomes one example per assistant step: mlx-lm with
--mask-prompt trains only on the last message of an example, so a turn with
three tool steps and an answer yields four examples, each ending at the step
it teaches. Steps with a call that Halo's validator rejected or that failed
(a tool error, not a declined approval) are never training targets, but stay
in the context of later steps so the model learns to recover from them.

Skipped by default: turns that ended in an error or were cancelled, and turns
the user corrected right after (next prompt within 3 minutes starting with
"no", "wrong", "that's not", ...).
"""

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timedelta

DEFAULT_TRACES = os.path.expanduser("~/Library/Application Support/Halo/Traces")
CORRECTIONS = ("no", "nope", "wrong", "that's not", "thats not", "not what", "didn't", "didnt", "incorrect",
               "undo", "stop", "try again", "you didn't", "that is not")


def load_traces(folder):
    traces = []
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".jsonl"):
            continue
        with open(os.path.join(folder, name), encoding="utf-8") as handle:
            for number, line in enumerate(handle, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    traces.append(json.loads(line))
                except json.JSONDecodeError:
                    print(f"skipping unreadable line {name}:{number}", file=sys.stderr)
    traces.sort(key=lambda t: t["date"])
    return traces


def read_blob(folder, digest, ext):
    if not digest:
        return None
    with open(os.path.join(folder, "blobs", f"{digest}.{ext}"), encoding="utf-8") as handle:
        return handle.read()


def corrected(trace, following):
    if following is None:
        return False
    gap = parse_date(following["date"]) - parse_date(trace["date"])
    text = following["prompt"].strip().lower()
    return gap <= timedelta(minutes=3) and text.startswith(CORRECTIONS)


def parse_date(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def arguments(text):
    try:
        value = json.loads(text) if text.strip() else {}
    except json.JSONDecodeError:
        return text
    return value


def failed(call):
    """Rejected by the validator, or a tool error. A declined approval is not a failure."""
    if call["rejected"]:
        return True
    try:
        output = json.loads(call["output"])
    except json.JSONDecodeError:
        return False
    return isinstance(output, dict) and output.get("ok") is False and not output.get("denied")


def examples(trace, system, tools):
    """One example per assistant step that is a valid training target."""
    messages = [{"role": "system", "content": system}]
    messages += [{"role": turn["role"], "content": turn["text"]} for turn in trace["history"]]
    messages.append({"role": "user", "content": trace["prompt"]})
    made = []
    call_number = 0
    for step in trace["steps"]:
        calls = []
        for call in step["calls"]:
            call_number += 1
            call["id"] = f"call_{call_number}"
            calls.append({"id": call["id"], "type": "function",
                          "function": {"name": call["name"], "arguments": arguments(call["arguments"])}})
        messages.append({"role": "assistant", "content": step["text"], "tool_calls": calls})
        if not any(failed(call) for call in step["calls"]):
            made.append({"messages": [dict(m) for m in messages], "tools": tools})
        for call in step["calls"]:
            messages.append({"role": "tool", "tool_call_id": call["id"], "name": call["name"], "content": call["output"]})
    if trace["answer"].strip():
        messages.append({"role": "assistant", "content": trace["answer"]})
        made.append({"messages": messages, "tools": tools})
    return made


def split(trace, test_domains):
    if test_domains:
        text = json.dumps(trace["steps"]).lower() + trace["prompt"].lower()
        return "test" if any(domain in text for domain in test_domains) else ("valid" if bucket(trace) < 10 else "train")
    value = bucket(trace)
    return "test" if value < 10 else "valid" if value < 20 else "train"


def bucket(trace):
    """Stable 0-99 bucket per trace, so a turn's steps never straddle splits."""
    return int(hashlib.sha256(trace["id"].encode()).hexdigest(), 16) % 100


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--traces", default=DEFAULT_TRACES, help="recorded traces folder")
    parser.add_argument("--out", required=True, help="folder for train/valid/test.jsonl")
    parser.add_argument("--system", help="file with a system prompt to use instead of the recorded one")
    parser.add_argument("--test-domains", default="", help="comma-separated sites held out for the test split only")
    parser.add_argument("--keep-corrected", action="store_true", help="keep turns the user corrected right after")
    args = parser.parse_args()

    traces = load_traces(args.traces)
    test_domains = [d.strip().lower() for d in args.test_domains.split(",") if d.strip()]
    override = open(args.system, encoding="utf-8").read() if args.system else None
    splits = {"train": [], "valid": [], "test": []}
    skipped = {"handled without the model": 0, "error or cancelled": 0, "corrected": 0, "no tools offered": 0}
    for index, trace in enumerate(traces):
        if trace["brain"] == "shortcut":
            skipped["handled without the model"] += 1
            continue
        if trace["outcome"]["end"] != "answered":
            skipped["error or cancelled"] += 1
            continue
        if not args.keep_corrected and corrected(trace, traces[index + 1] if index + 1 < len(traces) else None):
            skipped["corrected"] += 1
            continue
        tools_text = read_blob(args.traces, trace.get("tools"), "json")
        if tools_text is None:
            skipped["no tools offered"] += 1
            continue
        system = override or read_blob(args.traces, trace["instructions"], "txt")
        splits[split(trace, test_domains)] += examples(trace, system, json.loads(tools_text))

    os.makedirs(args.out, exist_ok=True)
    for name, rows in splits.items():
        with open(os.path.join(args.out, f"{name}.jsonl"), "w", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    kept = len(traces) - sum(skipped.values())
    print(f"{len(traces)} turns read, {kept} kept; skipped: "
          + ", ".join(f"{count} {reason}" for reason, count in skipped.items() if count) if kept < len(traces) else
          f"{len(traces)} turns read, all kept")
    print("examples: " + ", ".join(f"{name} {len(rows)}" for name, rows in splits.items()))


if __name__ == "__main__":
    main()
