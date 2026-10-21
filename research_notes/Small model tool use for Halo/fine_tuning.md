# Fine-tuning small language models for reliable tool calling

Scope: 1-8B models, 2024-2026 work, with a feasibility check for a solo developer on a 16 GB M1 using LoRA via mlx-lm (targets: Gemma 4 E2B, Qwen3.5-2B).

Evidence labels: **[Paper]** = peer-reviewed or arXiv paper abstract/text read; **[Vendor]** = authors' or model-card self-report; **[Secondary]** = third-party summary I could not check against the source; **[Inference]** = my reasoning, not a sourced claim.

Method note: about 17 tool calls. Several headline numbers come only from search snippets or secondary summaries and are marked as such. Verify the tables in the original papers before quoting them in Halo docs.

## Q1. What do SFT/LoRA on distilled or synthetic trajectories give small models?

### Takeaway
SFT on verified synthetic function-calling data is the most consistently reported win for small models. Reported gains are large on BFCL and API-Bank, but most numbers are vendor-reported. The best independent evidence is a 2026 controlled study showing LoRA SFT beats GRPO in-distribution.

### Cited Findings
- APIGen: a 60k verified function-calling dataset. A human review of 600 sampled points found over 95% correct. xLAM-7B-FC ranked 6th on BFCL at the 06/15/2024 snapshot with overall 85.65 [Vendor] — [APIGen paper](https://arxiv.org/pdf/2406.18518)
- xLAM model cards report xLAM-1b-fc-r at #3 and xLAM-7b-fc-r at #25 on BFCL at a later snapshot [Vendor, date-dependent] — via [APIGen search summary](https://arxiv.org/pdf/2406.18518); check [the BFCL leaderboard](https://gorilla.cs.berkeley.edu/leaderboard)
- ToolACE: 26,507 APIs, dialogs from multi-agent interplay, dual-layer (rule + model) verification. Authors say 8B models reach GPT-4-level performance [Vendor] — [ToolACE, arXiv 2409.00920](https://www.iclr.cc/virtual/2025/poster/30779)
- ToolACE-8B reportedly 84.67% BFCL vs GPT-4-1106-Preview 83.25% and Llama-3-8B-Instruct 77.83%; API-Bank Level-1 76.51% vs GPT-3.5-Turbo 72.24% [Secondary — third-party summary, numbers not checked against the paper] — via [ToolACE search summary](https://www.iclr.cc/virtual/2025/poster/30779)
- TinyAgent (Berkeley): 1.1B and 7B models fine-tuned on a curated function-calling dataset. Reported success 80.06% (1.1B) and 84.95% (7B) vs GPT-4-Turbo 79.08% [Secondary — not verified against the paper] — [TinyAgent, arXiv 2409.00608](https://arxiv.org/pdf/2409.00608v2)
- Controlled study (NeurIPS 2026 listing): six Qwen3 models from 0.6B to 32B. LoRA SFT was best in 15 of 18 in-distribution settings. LoRA beat full fine-tuning, which the authors say better preserves pretrained agentic behavior [Paper, abstract page] — [SFT or RL for Tool-Calling LLM Agents?](https://neurips.cc/virtual/2026/172354)
- Multi-turn RL on tau2-bench airline (trained on tau-bench v1 airline): Qwen3.5-4B base 63.8% → 66.7% with IRC [Paper, arXiv 2604.02869, secondary read] — [arXiv 2604.02869](https://arxiv.org/pdf/2604.02869)
- Qwen3-4B-tau2-sft1 (rejection-sampled SFT trajectories): pass@1 0.40 on the tau2 test split (100 tasks) [Vendor model card] — [HF card via Featherless](https://featherless.ai/models/Jarrodbarnes/Qwen3-4B-tau2-sft1)
- TinyLLM (version/setup unclear): xLAM-2-3b-fc-r 65.74% overall, 55.62% multi-turn; Qwen3-4B (prompt) 35.25% multi-turn; xLAM-2-1b-fc-r 8.38% multi-turn [Paper, numbers from search summary] — [arXiv 2511.22138](https://arxiv.org/pdf/2511.22138)

### Inferences
- Fine-tuning helps most where base models are weakest on multi-turn (TinyLLM: prompted Qwen3-4B 35% multi-turn vs xLAM-2-3B 56%). Part of that gap is training data, not parameter count.
- Benchmark numbers from different papers are not comparable (different BFCL versions, snapshots, and tau-bench variants).

### Gaps
- No verified per-model base-vs-SFT tables for Gemma 4 E2B or Qwen3.5-2B. None of the sources covered them.
- Exact BFCL v3 gains from SFT on the APIGen data (base vs tuned, same model) were not retrieved from the paper tables.

## Q2. Named projects and what they reported

### Takeaway
Most small-model projects report a same-model gain from data, not from new architecture. The reliable pattern is: verifiable synthetic data + SFT. Octopus v2 and TinyAgent make the strongest on-device claims, but their evidence is mostly self-reported.

### Cited Findings
- **xLAM / APIGen** (Salesforce): see Q1. Dataset on HF: xlam-function-calling-60k [Vendor] — [APIGen](https://arxiv.org/pdf/2406.18518)
- **APIGen-MT** (Salesforce, NeurIPS 2025 D&B): two-phase pipeline. Phase 1 builds task blueprints with ground-truth actions via an LLM reviewer committee with feedback loops. Phase 2 simulates user-agent conversations. Trajectories are kept only if they pass state-based and output-based checks. Released 5K trajectories. xLAM-2-fc-r (1B–70B) reportedly beats GPT-4o and Claude 3.5 on tau-bench and BFCL, especially multi-turn [Vendor, exact small-model table numbers not retrieved] — [APIGen-MT arXiv 2504.03601](https://arxiv.org/pdf/2504.03601)
- **ToolACE** (Huawei, ICLR 2025): see Q1 — [arXiv 2409.00920](https://www.iclr.cc/virtual/2025/poster/30779)
- **Hammer** (MadeAgents, arXiv 2410.04587, ICLR 2025): targets naming-convention overfitting. Uses function masking plus an augmented irrelevance dataset. Abstract claims SOTA on BFCL and outperforming larger models; no numbers in the abstract [Vendor]. Secondary: Hammer-7B is second only to GPT-4 on BFCL [Secondary]. Hammer2.0 is built on Qwen2.5 / Qwen2.5-Coder, trained on xlam-function-calling-60k plus xlam-irrelevance-7.5k [Vendor model card, via third-party pages] — [Hammer paper](https://arxiv.org/abs/2410.04587)
- **Gorilla / OpenFunctions, NexusRaven, Granite function calling, Watt-tool**: not researched in this pass.
- **Octopus v2** (Nexa AI, 2B): treats function selection as single-token classification via functional tokens. Reports 99.5% accuracy and 0.38s latency on Nexa's benchmark, vs Phi-3 at 45.7% [Vendor, HF model card]. License CC-BY-NC-4.0 (non-commercial) [Vendor card] — [HF card](https://huggingface.co/NexaAIDev/Octopus-v2). Octopus V3 is reported as sub-billion and matching GPT-4V on function calling [Vendor]. Benchmark not independently verified.
- **TinyAgent** (Berkeley SqueezeAILab): see Q1. A DeBERTa-v3-small tool retriever reportedly reaches 99.8% tool recall [Secondary]. Models and dataset are open-sourced [Paper claim, per search] — [arXiv 2409.00608](https://arxiv.org/pdf/2409.00608v2)
- **Tool-N1** (NVIDIA, ICLR 2026, 7B/14B): rule-based binary reward (format + tool-call correctness), GRPO. Reportedly beats GPT-4o on BFCL and API-Bank [Vendor]. On 5,518 distilled trajectories, SFT-then-RL did not always beat pure RL [Paper, secondary read] — [arXiv 2505.00024](https://arxiv.org/pdf/2505.00024), code at github.com/NVlabs/Tool-N1

### Inferences
- Octopus v2 is only useful for fixed, small function sets. It is not a general answer for multi-step agent work.
- Models from 1B–8B in these papers come from Qwen2.5/Qwen3 or xLAM-2 bases. Results for Gemma and Qwen3.5 are not known from these sources.

### Gaps
- Gorilla, NexusRaven, Granite, Watt-tool, and Hermes function-calling numbers were not checked.
- ToolBench and API-Bank per-model tables were not retrieved.

## Q3. Data techniques and their measured effect

### Takeaway
Verification of generated trajectories is the best-supported data technique. Function masking and irrelevance data are plausible and author-reported, but I did not find independent ablations in this pass. Mixing general chat data is supported only indirectly.

### Cited Findings
- Verification by execution and multi-stage checks (APIGen): human review found over 95% correct on 600 samples [Vendor] — [APIGen](https://arxiv.org/pdf/2406.18518)
- APIGen-MT keeps trajectories only when both state-based and output-based checks pass [Paper] — [APIGen-MT](https://arxiv.org/pdf/2504.03601)
- ToolACE dual-layer verification (rule + model) [Vendor] — [ToolACE](https://www.iclr.cc/virtual/2025/poster/30779)
- Function masking and irrelevance augmentation: Hammer claims they reduce naming-convention overfitting and make models more robust across benchmarks. No ablation numbers in the abstract [Vendor] — [Hammer](https://arxiv.org/abs/2410.04587)
- Dataset mixing: the NeurIPS 2026 controlled study reports that mixing datasets gives consistently strong transfer while staying close to specialized in-distribution performance [Paper, abstract page] — [NeurIPS 2026 study](https://neurips.cc/virtual/2026/172354)
- Multi-turn DPO without SFT degrades performance on most metrics; the authors recommend SFT first. One 8B run gained 17% in slot filling but lost 10% in relevance [Paper] — [DiaTool-DPO, arXiv 2504.02882](https://arxiv.org/pdf/2504.02882)
- Rejection sampling: keeping only passing rollouts for SFT (AfterQuery, Llama-3.1-8B on 1,057 rollouts) [Vendor blog, numbers not retrieved] — [AfterQuery](https://www.afterquery.com/blog/how-afterquery-expert-data-drives-model-performance-on-τ²-bench)

### Inferences
- Negative examples (irrelevance, when-not-to-call, when-to-ask) are the least tested in this set. They appear in Hammer and ToolACE-style datasets. Measured effect is unknown.
- Error recovery and multi-turn trajectories are supported mainly by APIGen-MT and tau2 SFT cards. There is no clean ablation.

### Gaps
- No independent ablation found for function masking, name/description shuffling, or irrelevance data on the same base model.
- No measured effect found for general chat data mixing on tool-call accuracy vs forgetting for models under 8B.

## Q4. Preference and RL methods (DPO, ORPO, GRPO)

### Takeaway
RL with verifiable rewards (GRPO) gives small gains over SFT in some settings, but it is not a clear win. The controlled 2026 study found SFT stronger in-distribution. DPO can hurt small models unless SFT comes first.

### Cited Findings
- ToolRL (Qian et al., NeurIPS 2025): GRPO with fine-grained reward decomposition. Abstract reports +17% over base models and +15% over SFT models [Paper abstract, benchmark names and base sizes not retrieved] — [arXiv 2504.13958](https://arxiv.org/pdf/2504.13958). Reward-scale and length-reward claims come from secondary summaries and are unverified.
- Tool-N1 (7B/14B): see Q2 [Vendor claims] — [arXiv 2505.00024](https://arxiv.org/pdf/2505.00024)
- Controlled study (six Qwen3 models, 0.6B–32B): GRPO won 29 of 54 cross-dataset transfer settings, but by under 1 point on average. SFT→GRPO was rarely the best [Paper, abstract page] — [NeurIPS 2026 study](https://neurips.cc/virtual/2026/172354)
- DiaTool-DPO (8B and 3.1B models): DPO alone degrades; needs SFT first [Paper] — [arXiv 2504.02882](https://arxiv.org/pdf/2504.02882)
- FinTrace: DPO slightly regresses at Qwen3-8B but gives the largest end-to-end gain at 32B [Paper, not 3B] — [arXiv 2604.10015](https://arxiv.org/pdf/2604.10015)
- No paper found that runs SFT vs DPO vs GRPO head-to-head on a 2–3B model for tool calling.

### Inferences
- For a 2B model, the evidence favors SFT on verified data first. GRPO is a later, optional step.
- ORPO: no tool-calling evidence found in this pass.

### Gaps
- ToolRL base-model sizes and benchmark table not verified.
- Compute for GRPO on small models (generations per prompt, step count) not found.

## Q5. Feasibility on a 16 GB M1 with mlx-lm

### Takeaway
SFT with LoRA or QLoRA on a 2B model at 4–8k tokens looks feasible on 16 GB. GRPO is harder because each step generates several rollouts. Official mlx-lm DPO/GRPO support was not confirmed. The third-party mlx-lm-lora package claims to cover SFT, DPO, ORPO, CPO, and GRPO.

### Cited Findings
- mlx-lm-lora (third-party, Goekdeniz-Guelmez): LoRA, DoRA, full-precision, and QLoRA at 4/6/8-bit. Algorithms listed: SFT, DPO, FTPO, CPO. Secondary sources also list ORPO and GRPO [Secondary, repo not read directly] — [mlx-lm-lora](https://github.com/Goekdeniz-Guelmez/mlx-lm-lora)
- Companion GUI MLX LoRA Studio lists SFT, DPO, FTPO, CPO, ORPO, GRPO, Online DPO, XPO, RLHF Reinforce, and PPO. Its stated minimum is 16 GB RAM, with 24 GB+ recommended for 13B+ [Vendor readme] — [MLX LoRA Studio](https://github.com/Goekdeniz-Guelmez/MLX-LoRA-Studio)
- Memory claims conflict: one source says 16 GB+ for 7B-class models is enough, another says 32 GB+ for 7B+ [Secondary, no benchmarks found] — [unsloth-mlx](https://github.com/masna-ai/unsloth-mlx), [DZone guide](https://dzone.com/articles/fine-tuning-llms-locally-using-mlx-lm-guide)

### Inferences
- [Inference] A 2B model with 4-bit QLoRA, rank 8–16, and 4–8k sequences should fit in 16 GB for SFT. Keep batch size at 1 with gradient accumulation and enable gradient checkpointing. Measure before relying on this.
- [Inference] GRPO needs several rollouts per prompt, each up to 4–8k tokens, so it is likely the bottleneck on 16 GB. Keep group size small and sequences short.
- [Inference] A usable first SFT run is probably in the hundreds to low thousands of verified trajectories. No source in this pass gave a number, so treat this as a guess to test.

### Gaps
- No official mlx-lm release notes or issues were checked for DPO/GRPO.
- No measured memory numbers for Gemma 4 E2B (~5B stored, per-layer embeddings) or Qwen3.5-2B at 4–8k context.
- No source gave examples-needed curves for tool calling.

## Not covered in this pass
- Gorilla/OpenFunctions, NexusRaven, Granite, Watt-tool, Hermes function calling
- Gemma 4 E2B and Qwen3.5-2B tool-calling baselines
- Error-recovery trajectories as a separate technique
- Official mlx-lm DPO/GRPO support status

## Suggested next steps
1. Read the APIGen-MT and ToolRL full-text tables for exact small-model numbers.
2. Check the BFCL leaderboard directly for current small-model scores.
3. Check mlx-lm GitHub for DPO/GRPO support and open memory issues.
4. Run a small SFT pilot on Qwen3.5-2B with verified trajectories, and measure memory before any GRPO attempt.
