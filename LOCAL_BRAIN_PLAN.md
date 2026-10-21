# Halo Local Brain Plan

_Created 2026-10-21. Owner: Abdirashiid Sammantar._

## Goal

Replace the cloud brains (ChatGPT, DeepSeek) with Halo's own on-device model that does
normal work by itself, including on websites it has never seen. ChatGPT is used only as a
teacher while building; the shipped product runs fully local.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Model | Qwen3.5-4B, 4-bit (~3.1 GB) | Best published tool-use scores under 5B (BFCL-V4 50.3, TAU2 79.9, vendor-reported), reads screenshots, Apache 2.0 |
| Upgrade path | Qwen3.5-9B | Only if 4B misses the pass mark |
| Rejected | Gemma 4 E4B | No published tool-use scores; ~8B stored weights; training likely exceeds 16 GB |
| Training tool | `mlx-lm` (LoRA on the 4-bit model) | Native on Apple Silicon; supports Qwen3.5; Soup adds a layer over the same thing |
| Thinking | Off | Voice needs fast replies |
| Shipping | Download on first launch (Hugging Face) | Keeps the app small and updates fast |

## Design review against Incredible (2026-10-21)

Reverse-engineering evidence about Incredible (Tauri/Rust/Swift, cloud LLMs) was reviewed. Its smooth behaviour comes from its tools and native checks, running on large cloud models, so it shows what good tools make possible, not what a 4B model can do. Copy its tools and safety checks, not its expectations.

Adopted:

- **Outcome scoring** — every test task checks the real end state with native probes (file contents, app/window state, tab address, media state, draft open and not sent), not only which tool was called. Claiming success when the probe says failure is the worst result.
- **Fault injection** in test mode (stale IDs, timeouts, permission errors, unexpected dialogs) to produce recovery examples in bulk; natural failures are too rare.
- **Compact observations** — one line per element, snapshot-prefixed IDs (`s7:e12`), size budget, and a diff after each action instead of a full re-read.
- **Context gathered up front** — focused app, window, selection, Finder folder and selection, open documents (Incredible's `screen-context` / `open-folders` modules suggest the same).
- **Held-out apps** as well as sites; element IDs shuffled at export; at most ~3% of examples per app or site.

Rejected or deferred:

- **Coordinate clicking** — rejected. Phase 3 removed coordinate fallbacks on purpose; unresolved targets fail closed.
- **Merging tools into fewer, larger ones** — deferred until the ChatGPT baseline shows which tools are confused.
- **Curriculum percentages** — a starting guess, not evidence.

Deterministic native code (never learned): action execution, permissions, approvals and blocked categories, input validation, element ID issuance and stale-state checks, observation budgets and diffs, scrubbing, site policy, step limits, cancellation, and the scoring probes.

## Phase status

| Phase | Status | Exit condition |
| --- | --- | --- |
| L0. Groundwork in Halo | Complete (2026-10-21) | One shared agent loop, tool-call validator, short scoped tool list; cloud brains still pass in the real app |
| L1. Recorder | Complete (2026-10-21) — switch it on in Settings → Privacy → Training data | Opt-in, scrubbed traces export to training JSONL |
| L2. Task list and test set | In progress — 87 tasks with outcome checks; `training/run_eval.py` runs and scores them; ChatGPT baseline next | Written "normal work" list, held-out websites, scoring script, ChatGPT baseline |
| L3. Data collection | Not started | 1,000–3,000 clean examples across many websites |
| L4. Training rounds | Not started | Pass mark met on the test set |
| L5. Local brain in Halo | Not started | "Local" brain works in the real app on the M1 at acceptable speed and memory |
| L6. Release | Not started | Clean public model, download flow, license notices |

## L0 — Groundwork in Halo

- [x] Commit the current uncommitted browser work first (17 files, plus `BrowserToolRunner.swift`).
- [x] Extract one `AgentLoop` in HaloCore that owns history, rounds, tool execution, and screenshots; ChatGPT and DeepSeek become one-round backends.
- [x] Add a tool-call validator (name exists, required keys, types, `enum`, `items`, no unknown keys); return errors to the model as tool results; at most 2 retries.
- [x] Send only the tools a request needs: browser-only requests drop Mac app-discovery and UI-control tools (16.0 KB → 11.4 KB). Descriptions kept as is; they carry safety rules, and the local model will be trained on compact ones.
- [ ] Add higher-level tools where a task currently takes many steps.
- [ ] **Freeze tool names and argument shapes** before L3. Renaming a tool later invalidates collected examples.

## L1 — Recorder

- [x] Record each turn as a trace: user text, tools offered, every tool call and result, final answer, and outcome (tool errors, rejected calls, approval denied; user corrections are detected at export).
- [x] Tool results are saved as the model saw them (capped at 16,000 characters); screenshots are never saved.
- [x] Scrub emails, phone and card numbers, keys, and the user name before writing; JSON values only, so IDs and structure survive. Names and free-form personal text are not caught — traces stay local.
- [x] Opt-in setting, off by default; `~/Library/Application Support/Halo/Traces`.
- [x] `training/export_traces.py`: traces → `train.jsonl` / `valid.jsonl` / `test.jsonl` in mlx-lm `{"messages", "tools"}` format, one example per assistant step (mlx-lm `--mask-prompt` trains only the last message); rejected or failed calls stay as context, never as targets; `--test-domains` holds sites out for testing.

## L2 — Task list and test set

- [ ] Write the "normal work" list (tabs, media, apps, files, windows, search, forms, …).
- [ ] Pick 20–30 held-out websites that never appear in training.
- [ ] Scoring script: right tool, right arguments, task succeeded, time to first step.
- [ ] Run ChatGPT on the test set as the baseline to beat.

## L3 — Data collection

- [ ] Collect examples with ChatGPT driving Halo; keep only clean episodes.
- [ ] Prioritise many different websites over many examples per site.
- [ ] Include the hard paths: tool errors reported honestly, denied approvals, unclear requests answered with a question, "I can't do that yet", invalid call then corrected retry.
- [ ] Check licenses before using any public dataset (for example Mind2Web).

## L4 — Training rounds

- [x] `~/halo-train` venv with mlx-lm 0.32.2; `mlx-community/Qwen3.5-4B-4bit` loads and, untrained, already makes correct calls for running_apps and read_file (2026-10-21). Chat template needs `enable_thinking=False`.
- [ ] Train: `mlx_lm.lora --train --batch-size 1 --mask-prompt --grad-checkpoint --max-seq-length 4096`.
- [ ] Score on the test set; collect examples for failures; retrain (expect 3–5 rounds).
- [ ] Pass mark: ≥ 90% on the normal-work list, plus a target on held-out sites set after the baseline.
- [ ] If 4B misses the pass mark after several rounds, try 9B.
- [ ] Later: screenshot training with `mlx-vlm`.

## L5 — Local brain in Halo

- [ ] `MLXBackend` in-process via mlx-swift; check the Metal library builds with Halo's build scripts.
- [ ] **Must-do: cache the fixed prompt.** Measured 2026-10-21 on the M1 with the untrained model: Halo's system prompt plus tool list is ~5,800 tokens and takes ~34 s to read before every step (prefill ~170 tokens/s; writing ~20 tokens/s; 2.5 GB peak memory). That block is identical every time, so compute it once, save it (mlx-lm prompt cache), and reuse it across steps and requests; each step then reads only the new tokens.
- [ ] Shorter tool descriptions, trained into the model, to shrink the cached block further.
- [ ] "Local" option in Brain settings.
- [ ] Measure on the M1: time to first step, words per second, memory.
- [ ] Approval gates unchanged — a small model is easier to trick with page content.

## L6 — Release

- [ ] Train the public model on scrubbed or synthetic examples only; never ship a model trained on private conversations.
- [ ] Host on Hugging Face; first-launch download with progress and checksum.
- [ ] Include the Apache 2.0 license and a modification notice.
- [ ] Fold into OpenClaw Phase 7 release hardening.

## Risks

- Vendor benchmark scores are unverified; the test set decides.
- Prompt reading speed on the M1 is unmeasured; long tool lists are the main slowdown.
- Unfamiliar or complex websites stay the weakest area even after training.
