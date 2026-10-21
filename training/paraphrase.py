#!/usr/bin/env python3
"""Write natural rewordings of the practice requests, so collection covers more phrasing.

    python3 -I training/paraphrase.py            # fill in missing rewordings
    python3 -I training/paraphrase.py --per 5    # rewordings wanted per request

Asks DeepSeek (key from the project .env, the same one Halo uses) for
rewordings of each practice prompt. Only the practice templates are sent,
never user data. A rewording is kept only if it still contains everything the
task's setup and checks depend on (paths, sites, app names, quoted text, the
words a file must contain), is not an exam prompt, names no held-out site,
and is not an "open X" request that Halo's local shortcut would answer
without the model. Results are cached in practice_variants.json.
"""

import argparse
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import practice_tasks  # noqa: E402

CACHE = os.path.join(HERE, "practice_variants.json")
ENV = os.path.join(os.path.dirname(HERE), ".env")
# Python copy of AppResolver.launchTarget's pattern: such requests skip the model.
SHORTCUT = re.compile(r"^(?:(?:hey\s+)?mercy[,!\s]+)?(?:(?:can|could|would)\s+you\s+)?(?:please\s+)?"
                      r"(?:open|launch|start|switch\s+to|bring\s+up|activate)\s+(.+?)(?:\s+please)?[.!?]*$", re.I)


def api_key():
    for line in open(ENV, encoding="utf-8"):
        if line.startswith("DEEPSEEK_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"')
    raise SystemExit("DEEPSEEK_API_KEY is not set in .env")


def required(task):
    """Exact strings a rewording must keep for the setup and checks to stay valid."""
    prompt = task["prompt"]
    tokens = set(re.findall(r"~/[\w./-]+", prompt))
    tokens |= set(re.findall(r"\b[\w-]+\.(?:com|org|no|net|io)(?:/[\w/]+)?", prompt))
    tokens |= set(re.findall(r"'([^']+)'", prompt))
    tokens |= set(re.findall(r"\b[\w-]+/[\w.-]+\b", prompt)) - {t for t in tokens if t.startswith("~")}
    for check in task["checks"]:
        if check.get("app") and check["app"].lower() in prompt.lower():
            tokens.add(check["app"])
        if check["check"] in ("file_contains", "textedit_text") and check["text"] and check["text"].lower() in prompt.lower():
            tokens.add(check["text"])
    for name in practice_tasks.FILES:
        if name in prompt:
            tokens.add(name)
    return sorted(t for t in tokens if t)


def ask(key, prompt, keep, count):
    instructions = (f"Rewrite this request to a Mac assistant in {count} different natural ways a person might say or type it. "
                    "Keep the meaning and every detail. Vary length, tone, and word order; some casual, some polite. "
                    + (f"Each rewrite must contain these exactly: {', '.join(repr(k) for k in keep)}. " if keep else "")
                    + "Do not start with the words open, launch, start, or activate. "
                    'Reply with only a JSON array of strings.\n\nRequest: ' + prompt)
    body = json.dumps({"model": "deepseek-flash", "max_tokens": 800, "thinking": {"type": "disabled"},
                       "messages": [{"role": "user", "content": instructions}]}).encode()
    request = urllib.request.Request("https://api.deepseek.com/chat/completions", data=body,
                                     headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        text = json.load(response)["choices"][0]["message"]["content"]
    match = re.search(r"\[.*\]", text, re.S)
    return [v.strip() for v in json.loads(match.group(0)) if isinstance(v, str)] if match else []


def valid(variant, task, keep, exam_prompts, held_out):
    lower = variant.lower()
    if not variant or len(variant) > 300 or SHORTCUT.match(variant.strip()):
        return False
    if practice_tasks.norm(variant) in exam_prompts or practice_tasks.norm(variant) == practice_tasks.norm(task["prompt"]):
        return False
    if any(site in lower for site in held_out) or any(re.search(r"\b" + app + r"\b", variant) for app in practice_tasks.HELD_OUT_APPS):
        return False
    return all(k.lower() in lower for k in keep)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--per", type=int, default=5)
    args = parser.parse_args()
    exam = json.load(open(os.path.join(HERE, "eval_tasks.json")))
    exam_prompts = {practice_tasks.norm(t["prompt"]) for t in exam["tasks"]}
    cache = json.load(open(CACHE)) if os.path.exists(CACHE) else {}
    key = api_key()
    tasks = practice_tasks.generate(variants=False)
    added = rejected = 0
    for number, task in enumerate(tasks, 1):
        have = cache.setdefault(task["prompt"], [])
        if len(have) >= args.per:
            continue
        keep = required(task)
        try:
            proposals = ask(key, task["prompt"], keep, args.per + 2)
        except Exception as error:
            print(f"  skipped {task['id']}: {error}", file=sys.stderr)
            continue
        for variant in proposals:
            if len(have) >= args.per:
                break
            if variant not in have and valid(variant, task, keep, exam_prompts, exam["held_out_sites"]):
                have.append(variant)
                added += 1
            else:
                rejected += 1
        if number % 10 == 0:
            json.dump(cache, open(CACHE, "w"), indent=1, ensure_ascii=False)
            print(f"{number}/{len(tasks)} requests, {added} rewordings kept, {rejected} rejected", flush=True)
    json.dump(cache, open(CACHE, "w"), indent=1, ensure_ascii=False)
    print(f"Done: {added} rewordings kept, {rejected} rejected; {sum(len(v) for v in cache.values())} in {CACHE}")


if __name__ == "__main__":
    main()
