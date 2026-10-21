#!/usr/bin/env python3
"""Qualify a local model offline: its first move on every exam request.

    ~/halo-train/bin/python -I training/qualify.py mlx-community/gemma-4-E2B-it-4bit
    ~/halo-train/bin/python -I training/qualify.py MODEL --adapter adapters/   # after training

For each task in eval_tasks.json the model gets Halo's real system prompt and
the tool list Halo would send for that request (browser-only requests drop
the Mac app and UI tools, as ToolScope does), with the fixed prompt cached as
Halo would cache it. Only the first step is generated and judged; nothing runs
on the Mac. This screens a model before it is wired into Halo; the full exam
(run_eval.py) still decides.

A first move is: right (a tool the task expects, or no tool for a chat
task), prep (a look-first tool), announced (text and no call when the task
needs an action), or wrong. Tool inputs are checked against the tool's
schema with the same rules as Halo's ToolValidator.
"""

import argparse
import copy
import json
import os
import re
import statistics
import time

import mlx.core as mx
from mlx_lm import load, stream_generate
from mlx_lm.models.cache import make_prompt_cache

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = os.path.join(os.path.dirname(HERE), "HaloNative", "Sources")
LOOKS = {"running_apps", "list_apps", "list_windows", "inspect_ui", "list_files", "list_browser_tabs", "read_browser_tab",
         "screen_info", "list_menus", "find_dialog", "authorize_browser_tab", "inspect_screen"}
APP_DISCOVERY = {"list_apps", "running_apps", "open_app", "inspect_ui"}
MAC_CONTROL = {"ui_action", "type_text", "keypress", "scroll", "focus_app", "list_windows", "list_menus", "click_menu_item",
               "find_dialog", "click_dialog_button", "window_layout", "screen_info"}
BROWSER_WORDS = {"chrome", "browser", "tab", "tabs", "website", "websites", "site", "webpage", "url", "link", "youtube", "netflix",
                 "gmail", "google", "reddit", "amazon", "twitter", "facebook", "instagram", "linkedin", "github", "wikipedia",
                 "spotify", "twitch", "hulu", "vimeo", "disney"}
MAC_WORDS = {"window", "windows", "arrange", "layout", "menu", "menus", "dialog", "finder", "desktop", "display", "monitor"}


def halo_prompt_and_tools():
    source = open(os.path.join(SOURCES, "Halo", "MacTools.swift")).read()
    tools = json.loads(source[source.index('toolDefinitions = Data(#"""') + 27:source.index('"""#')])
    system = re.search(r'assistantInstructions = "(.*?)"\n', open(os.path.join(SOURCES, "HaloCore", "DeepSeekProvider.swift")).read()).group(1)
    return system, tools


def scoped(tools, prompt):
    """ToolScope.definitions: browser-only requests drop app-discovery and Mac UI tools."""
    lower = prompt.lower()
    words = set(re.findall(r"[a-z0-9]+", lower))
    browser = ("http://" in lower or "https://" in lower or "www." in lower or "web page" in lower
               or re.search(r"\b[a-z0-9-]+\.(com|net|org|io|co|tv|app|dev|ai|edu|gov|me|uk|ca|de)\b", lower) or words & BROWSER_WORDS)
    if not browser or words & MAC_WORDS:
        return tools
    return [t for t in tools if t["function"]["name"] not in APP_DISCOVERY | MAC_CONTROL]


def parse_calls(text):
    """Tool calls in Gemma 4 (<|tool_call>call:name{...}) or Qwen (<function=name><parameter=...>) format."""
    calls = []
    for name, body in re.findall(r"call:([\w-]+)\{(.*?)\}\s*<tool_call\|>", text, re.S):
        raw = "{" + body.replace('<|"|>', '"') + "}"
        raw = re.sub(r'([{,]\s*)([A-Za-z_][\w]*)\s*:', r'\1"\2":', raw)
        try:
            calls.append((name, json.loads(raw)))
        except json.JSONDecodeError:
            calls.append((name, None))
    for name, body in re.findall(r"<function=([\w-]+)>(.*?)</function>", text, re.S):
        args = {}
        for key, value in re.findall(r"<parameter=([\w-]+)>\s*(.*?)\s*</parameter>", body, re.S):
            try:
                args[key] = json.loads(value)
            except json.JSONDecodeError:
                args[key] = value
        calls.append((name, args))
    return calls


def problem(value, schema, path):
    """ToolValidator's checks: required, types, enums, items, unknown arguments."""
    if "enum" in schema and value not in schema["enum"]:
        return f"{path} not one of {schema['enum']}"
    kind = schema.get("type")
    if kind == "object":
        if not isinstance(value, dict):
            return f"{path} must be an object"
        properties = schema.get("properties", {})
        for key in schema.get("required", []):
            if value.get(key) in (None,):
                return f"{path} missing {key}"
        for key, item in value.items():
            if key not in properties:
                return f"{path} unknown {key}"
            if item is not None and (issue := problem(item, properties[key], f"{path}.{key}")):
                return issue
    elif kind == "array":
        if not isinstance(value, list):
            return f"{path} must be an array"
    elif kind == "string" and not isinstance(value, str):
        return f"{path} must be a string"
    elif kind == "integer" and (isinstance(value, bool) or not isinstance(value, (int, float)) or value != int(value)):
        return f"{path} must be a whole number"
    elif kind == "boolean" and not isinstance(value, bool):
        return f"{path} must be true or false"
    return None


def judge(task, calls, text):
    expect, avoid = task.get("expect_tools", []), task.get("avoid_tools", [])
    names = [n for n, _ in calls]
    if not expect:
        if "*" in avoid:
            return "right" if not names else "wrong"
        return "wrong" if any(n in avoid for n in names) else "right"
    if not names:
        return "announced"
    if names[0] in expect:
        return "right"
    if names[0] in avoid:
        return "wrong"
    return "prep" if names[0] in LOOKS else "wrong"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("model")
    parser.add_argument("--adapter", help="LoRA adapter folder from training")
    parser.add_argument("--only", default="", help="comma-separated task ids or categories")
    parser.add_argument("--show-wrong", action="store_true")
    args = parser.parse_args()

    system, all_tools = halo_prompt_and_tools()
    tasks = json.load(open(os.path.join(HERE, "eval_tasks.json")))["tasks"]
    if args.only:
        wanted = {w.strip() for w in args.only.split(",")}
        tasks = [t for t in tasks if t["id"] in wanted or t["category"] in wanted]
    model, tokenizer = load(args.model, adapter_path=args.adapter)
    schemas = {t["function"]["name"]: t["function"].get("parameters", {"type": "object", "properties": {}}) for t in all_tools}

    def render(tools, request):
        return tokenizer.apply_chat_template([{"role": "system", "content": system}, {"role": "user", "content": request}],
                                             tools=tools, add_generation_prompt=True, tokenize=False, enable_thinking=False)

    prefixes = {}
    rows = []
    for task in tasks:
        tools = scoped(all_tools, task["prompt"])
        key = tuple(t["function"]["name"] for t in tools)
        if key not in prefixes:  # the fixed part, read once per tool list as Halo would cache it
            marker = "QUALIFYMARKER"
            full = render(tools, marker)
            tokens = tokenizer.encode(full[:full.index(marker)])
            cache = make_prompt_cache(model)
            model(mx.array(tokens)[None], cache=cache)
            mx.eval([c.state for c in cache])
            prefixes[key] = (len(tokens), cache)
        prefix_length, cache = prefixes[key]
        rest = tokenizer.encode(render(tools, task["prompt"]))[prefix_length:]
        start, first, text = time.time(), None, ""
        for piece in stream_generate(model, tokenizer, prompt=rest, max_tokens=160, prompt_cache=copy.deepcopy(cache)):
            first = first or time.time() - start
            text += piece.text
        seconds = time.time() - start
        calls = parse_calls(text)
        verdict = judge(task, calls, text)
        issues = [f"{name}: unreadable arguments" if args_ is None else problem(args_, schemas.get(name, {}), name)
                  if name in schemas else f"{name}: no such tool" for name, args_ in calls]
        rows.append({"id": task["id"], "category": task["category"], "verdict": verdict, "calls": [n for n, _ in calls],
                     "valid": not any(issues), "issues": [i for i in issues if i], "first": first, "seconds": seconds,
                     "held_out": bool(task.get("held_out_site")), "text": text.strip()[:160]})
        print(f"{task['id']:<12} {verdict:<10} {'valid' if not any(issues) else 'INVALID':<8} {seconds:5.1f} s  {[n for n, _ in calls]}", flush=True)

    def share(rows, verdict):
        return f"{100 * sum(r['verdict'] == verdict for r in rows) / len(rows):5.1f}%" if rows else "  n/a"
    called = [r for r in rows if r["calls"]]
    print(f"\n{args.model}{' + ' + args.adapter if args.adapter else ''}: {len(rows)} tasks")
    print(f"  right first move   {share(rows, 'right')}   (familiar {share([r for r in rows if not r['held_out']], 'right').strip()},"
          f" new sites {share([r for r in rows if r['held_out']], 'right').strip()})")
    print(f"  look-first prep    {share(rows, 'prep')}")
    print(f"  announced, no call {share(rows, 'announced')}")
    print(f"  wrong              {share(rows, 'wrong')}")
    print(f"  valid tool inputs  {100 * sum(r['valid'] for r in called) / max(1, len(called)):5.1f}% of {len(called)} calls")
    print(f"  first word         {statistics.median(r['first'] for r in rows):.2f} s median;  step done {statistics.median(r['seconds'] for r in rows):.1f} s median")
    if args.show_wrong:
        for r in rows:
            if r["verdict"] in ("wrong", "announced") or r["issues"]:
                print(f"  {r['id']:<12} {r['verdict']:<10} {r['issues'][:1]} {r['text'][:110]!r}")
    out = os.path.expanduser("~/Library/Application Support/Halo/Eval/qualify")
    os.makedirs(out, exist_ok=True)
    name = re.sub(r"[^\w.-]+", "_", args.model + ("-" + args.adapter if args.adapter else ""))
    json.dump(rows, open(os.path.join(out, f"{name}.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
