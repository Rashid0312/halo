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

## Phase status

| Phase | Status | Exit condition |
| --- | --- | --- |
| L0. Groundwork in Halo | Not started | One shared agent loop, tool-call validator, short scoped tool list; cloud brains still pass in the real app |
| L1. Recorder | Not started | Opt-in, scrubbed traces export to training JSONL |
| L2. Task list and test set | Not started | Written "normal work" list, held-out websites, scoring script, ChatGPT baseline |
| L3. Data collection | Not started | 1,000–3,000 clean examples across many websites |
| L4. Training rounds | Not started | Pass mark met on the test set |
| L5. Local brain in Halo | Not started | "Local" brain works in the real app on the M1 at acceptable speed and memory |
| L6. Release | Not started | Clean public model, download flow, license notices |

## L0 — Groundwork in Halo

- [ ] Commit the current uncommitted browser work first (17 files, plus `BrowserToolRunner.swift`).
- [ ] Extract one `AgentLoop` in HaloCore that owns history, rounds, tool execution, and screenshots; ChatGPT and DeepSeek become one-round backends.
- [ ] Add a tool-call validator (name exists, required keys, types, `enum`, `items`, no unknown keys); return errors to the model as tool results; at most 2 retries.
- [ ] Shorten tool descriptions and send only the tools a request needs (extend `ToolScope`).
- [ ] Add higher-level tools where a task currently takes many steps.
- [ ] **Freeze tool names and argument shapes** before L3. Renaming a tool later invalidates collected examples.

## L1 — Recorder

- [ ] Record each turn as a trace: user text, tools offered, every tool call and result, final answer, and outcome (tool errors, user correction, approval denied).
- [ ] Trim tool results exactly as inference will.
- [ ] Scrub private data (emails, file contents, page text with personal details) before writing to disk.
- [ ] Opt-in setting, off by default; local folder only.
- [ ] Export command: traces → `train.jsonl` / `valid.jsonl` / `test.jsonl` in mlx-lm `{"tools", "messages"}` format.

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

- [ ] Set up `~/halo-train` venv with `mlx-lm`; confirm `mlx-community/Qwen3.5-4B-4bit` loads.
- [ ] Train: `mlx_lm.lora --train --batch-size 1 --mask-prompt --grad-checkpoint --max-seq-length 4096`.
- [ ] Score on the test set; collect examples for failures; retrain (expect 3–5 rounds).
- [ ] Pass mark: ≥ 90% on the normal-work list, plus a target on held-out sites set after the baseline.
- [ ] If 4B misses the pass mark after several rounds, try 9B.
- [ ] Later: screenshot training with `mlx-vlm`.

## L5 — Local brain in Halo

- [ ] `MLXBackend` in-process via mlx-swift; check the Metal library builds with Halo's build scripts.
- [ ] Reuse the model's cache between rounds of one request.
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
