# Hybrid small-local / large-cloud architectures for Halo

Scope: a Gemma 4 E2B model on a Mac runs all tools and holds sensitive data; a larger cloud model (DeepSeek API) helps with hard tasks and must never see sensitive content. Research date: 2026-10-21. Measured results are marked [measured]; vendor or author claims are marked [claim]. Several sources were abstract-only, which is noted where it applies.

## 1. Routing and cascades (RouteLLM, FrugalGPT, AutoMix, escalation signals)

### Takeaway
Cascades and learned routers reliably cut cost by 2x or more on general benchmarks, but the reported numbers come from chat-style tasks with cheap verifiers. Nothing found measures a small-model-first cascade on privacy-sensitive, tool-using agent tasks, so Halo would need its own evaluation. Of the escalation signals, trained probes and perplexity-style signals appear stronger than verbalized self-confidence, though that comes from abstract-level secondary reading.

### Cited Findings
- RouteLLM (Ong et al., ICLR 2025) trains routers on human preference data to pick between a strong and a weak model per query; the abstract reports cost reductions of "over 2x" on public benchmarks without loss of response quality, and says routers keep performing when routing to models not seen in training. [RouteLLM arXiv](https://arxiv.org/abs/2406.18665); [ICLR 2025 proceedings](https://proceedings.iclr.cc/paper_files/paper/2025/hash/5503a7c69d48a2f86fc00b3dc09de686-Abstract-Conference.html). [measured on public benchmarks; the abstract-page fetch gave no PGR/MT-Bench/MMLU numbers, so the per-benchmark tables were not verified]
- FrugalGPT (Chen et al., 2023) is an LLM cascade with a learned response evaluator. Headline: match GPT-4 performance at up to 98% lower inference cost, or +4% accuracy at equal cost. The HEADLINES case study cut cost by 80% while gaining 1.5% accuracy over GPT-4. The gains depend on cheap models being right where GPT-4 is wrong (about 6% of the data). Secondary coverage notes the evaluator needs labeled data to train. [FrugalGPT arXiv](https://arxiv.org/pdf/2305.05176); [BDTechTalks commentary](https://bdtechtalks.com/2023/06/12/reduce-costs-of-chatgpt-gpt-4/) [measured, 2023 models, classification-style tasks]
- AutoMix (Madaan et al.) sends a query to a small model first, self-verifies the answer by entailment against the context using repeated sampling, and escalates when verification fails; a POMDP meta-verifier refines the decision. Reported savings vary across versions: arXiv v4 says "over 50%" compute reduction for comparable performance; v1 cited up to 86% benefit-per-cost; the NeurIPS workshop version cited up to 57%. [AutoMix arXiv](https://arxiv.org/pdf/2310.12963); [mlanthology NeurIPS-W](https://mlanthology.org/neuripsw/2023/madaan2023neuripsw-automix) [claim; version-dependent]
- Confidence Tokens / Self-REF (Chuang et al., ICML 2025): models trained to emit confidence tokens; reported to beat verbalized confidence and token-probability baselines for routing and rejection. [mlanthology ICML 2025](https://mlanthology.org/icml/2025/chuang2025icml-learning); [arXiv html](https://arxiv.org/html/2410.13284v2) [abstract-level only]
- A 2026 survey reports that, in a benchmark by the same group, probe-based and perplexity-based uncertainty methods outperform verbalized self-reported confidence for routing from small models to large ones on edge devices. Trained hidden-state probes (Mahaut et al., 2024) were the most reliable but need model weights and supervision. [Dynamic Model Routing survey, arXiv 2603.04445](https://arxiv.org/pdf/2603.04445) [secondary summary; not verified in full text]
- A 2026 paper finds LLMs can predict failure risk from their own confidence, but confidence alone does not tell you which collaboration protocol will pay off. [arXiv 2608.14927](https://arxiv.org/pdf/2608.14927) [abstract-level only]
- CP-Router (Su et al., 2025) uses conformal prediction over option probabilities to route between standard LLMs and reasoning models. [cited via arXiv 2603.04445 survey](https://arxiv.org/pdf/2603.04445) [abstract-level only]

### Inferences
- For Halo, the cheapest escalation signals that can be computed locally are: (a) token-level log-probabilities or entropy from the local model (available in MLX/llama.cpp-style runtimes), (b) hard validator failures (JSON/tool-schema parse errors, tool-call errors, unresolved references), and (c) step-count or retry budgets. Verbalized confidence from a 2B model is the weakest of these and should not be the only gate.
- AutoMix's self-verification pattern maps to Halo's situation: Gemma E2B checks its own tool plan against the schema and the user's request before any escalation decision. The check runs entirely on-device, so it adds no cloud exposure.
- Cascades with cloud fallback only pay off if the local model is right most of the time. Halo's cost case depends on the local hit rate, which needs measuring on Halo's own tasks.

### Gaps
- No measured cascade result was found for small on-device models doing tool use with a privacy constraint. The RouteLLM and FrugalGPT numbers come from chat and classification benchmarks.
- The RouteLLM per-benchmark tables (PGR, MT-Bench, MMLU, GSM8K) were not extracted; only the abstract claim was verified.
- No measured comparison was found of token-probability versus validator-based escalation for agent loops.

## 2. Planner-executor splits (LLMCompiler, TinyAgent, Plan-and-Act, α-UMi, HuggingGPT-style)

### Takeaway
Splitting planning from execution works, and the small-executor case is well supported: α-UMi (7B, multi-LLM) and TinyAgent (1.1B/7B, fine-tuned) match or beat GPT-4-class single-model baselines on their own tool-use benchmarks. The big caveat is that these results come from models fine-tuned on each benchmark's tool APIs. They do not show that an untuned E2B model can plan well.

### Cited Findings
- α-UMi ("Small LLMs Are Weak Tool Learners", EMNLP 2024) splits the agent into a planner, a caller and a summarizer, each a fine-tuned copy of one backbone trained with global-to-local progressive fine-tuning (GLPFT). [arXiv html v2](https://arxiv.org/html/2401.07324v2)
  - ToolBench in-domain, plan accuracy: α-UMi 7B 88.92 vs GPT-4 (0-shot) 80.28; single-LLM 13B 81.01. Hallucination rate: α-UMi 7B 0.57% vs GPT-4 5.98%. [measured, Table 1]
  - ToolAlpaca Proc./Ans.: α-UMi 7B 41/35; GPT-4 41/44; single 7B 11/11. [measured, Table 1]
  - MATH / GSM8K: α-UMi 7B 25.60 / 49.73 vs single 7B 17.38 / 37.90. [measured, Table 4]
  - GLPFT ablation: one-stage multi-LLM training drops ToolAlpaca Proc. from 41 to 2. [measured, Table 1]
  - Real-time ToolBench: α-UMi 7B 70.9 pass / 65.9 win; GPT-4 (DFSDT) 71.1 / 70.4. [measured, Table 2]
- TinyAgent (Erdogan et al., 2024, Berkeley) fine-tunes 1.1B and 7B models for function calling with a fine-tuned DeBERTa tool retriever. [TinyAgent arXiv html](https://arxiv.org/html/2409.00608v1)
  - Function-calling success: GPT-3.5 65.04%; GPT-4-Turbo 79.08%; TinyAgent-1.1B 80.06% (4-bit 80.35%); TinyAgent-7B 84.95% (4-bit 85.14%). [measured, Table 2; the authors' benchmark]
  - Fine-tuning raised the 1.1B model from 12.71% to 78.89%, and the 7B from 41.25% to 83.09%. [measured, Sec. 3.3]
  - Tool RAG cut the prompt from 2762 to about 1397 tokens (about 2x) while raising success over the no-RAG baseline (1.1B 78.89 to 80.06). Note: the paper's own text is inconsistent on basic-RAG top-k (top 6 in Sec. 3.4, top 3 in the Table 1 caption). [measured, Table 1]
  - Latency (Table 2): TinyAgent-1.1B 4-bit 2.9 s; GPT-4-Turbo 3.9 s; TinyAgent-7B 4-bit 13.1 s. The 7B model is too slow for interactive use on that hardware. The MacBook hardware is not specified. [measured]
- LLMCompiler (Kim et al., ICML 2024): a planner emits a DAG of function calls, and an executor runs independent calls in parallel. Abstract claims: up to 3.7x latency speedup, up to 6.7x cost savings, and up to ~9% accuracy gain over ReAct. [LLMCompiler arXiv](https://arxiv.org/abs/2312.04511v2); [ICML 2024 poster](https://icml.cc/virtual/2024/poster/32829) [claim, "up to" best-case figures; a secondary summary reports up to 1.35x over OpenAI's native parallel calling]
- Plan-and-Act (Erdogan et al., ICML 2025) separates a planner (high-level steps) from an executor (environment-specific actions), with synthetic plan data for training the planner. Reported web-navigation results: 57.58% on WebArena-Lite and 81.36% on WebVoyager (later revision; v2 reported 54%). [Plan-and-Act arXiv v3](https://arxiv.org/html/2503.09572v3); [ICML 2025 proceedings](https://proceedings.mlr.press/v267/erdogan25a.html) [measured on web navigation, not tool-calling]
- HuggingGPT-style (LLM controller dispatching to specialist models) was not re-verified in this pass.

### Inferences
- The most reliable pattern for Halo is "large plans, small executes": the cloud model writes a sanitized plan of tool calls with placeholders, and Gemma E2B fills arguments from local data and runs the tools. The cloud model never sees the private values. This matches the α-UMi and Plan-and-Act structure, with the planner in the cloud.
- The reverse split (small model plans, cloud model handles only the hard reasoning step) is the simpler one for privacy: the cloud gets a single, redacted sub-question, and the small model keeps the tools and the data.
- TinyAgent's retrieval step (fine-tuned small encoder to pick a few tools from a large catalogue) is worth copying directly, since it shrinks the prompt a small model has to handle.
- A 2B-class model is much smaller than the 1.1B/7B tuned models above. Fine-tuning on Halo's own tool-call traces (Halo already collects training examples, per recent commits) is the most likely path to comparable accuracy. This is an inference, not a measured result.

### Gaps
- No measured result was found for an untuned Gemma E2B-class model on tool use. Every number above comes from models fine-tuned on the benchmark's own tools.
- TinyAgent's MacBook latency figure was not given in the paper; only relative numbers are available.
- LLMCompiler's "up to" figures are best-case results on specific benchmarks.

## 3. Privacy-preserving local/cloud collaboration

### Takeaway
PAPILLON is the closest published match to Halo's need. A local model rewrites or redacts each request before the cloud model sees it, and the reported leakage is low. The reported quality retention (85.5%) is not close to cloud-only quality, so the trade-off has to be designed for. The numbers come from user-chat PII benchmarks, not from tool-using agents with sensitive files.

### Cited Findings
- PAPILLON (Li et al., NAACL 2025) defines "Privacy-Conscious Delegation": a local model handles sensitive content and a cloud model handles generation. It is a multi-stage pipeline with DSPy-optimized prompts. [PAPILLON arXiv](https://arxiv.org/pdf/2410.17127); [ACL Anthology 2025.naacl-long.173](https://aclanthology.org/2025.naacl-long.173)
  - Best configuration (per the abstract): local Llama-3.1-8B-Instruct with cloud GPT-4o-mini. Maintains high response quality for 85.5% of queries and restricts privacy leakage to 7.5%. [measured on the PUPA benchmark; abstract-page fetch only, so the cloud-only baseline was not confirmed]
  - The authors say a large quality gap to proprietary models remains. Code: [Columbia-NLP-Lab/PAPILLON](https://github.com/Columbia-NLP-Lab/PAPILLON). [claim about the gap; abstract]
- Halo's split (local Gemma does PII redaction before any DeepSeek call) matches PAPILLON's architecture. The 8B local model in PAPILLON is larger than E2B, so a smaller local redactor would probably leak more. This is an inference that needs measurement.

### Inferences
- Measured leakage for PAPILLON is a PII-exposure rate on a fixed benchmark. It is not a guarantee. For Halo, define the redaction set explicitly (names, account numbers, paths, emails, document text) and treat "quotes of private text" as a separate leakage class.
- Data minimization that does not depend on a model (send only the minimal structured fields, never raw file contents) gives a hard guarantee that model-based redaction cannot.
- Local summarization before cloud calls reduces leakage but can also drop facts the cloud model needs. Halo should test the quality cost on its own tasks.

### Gaps
- No measured results were found for cloud-side access under other local-redaction schemes (differential-privacy-style or abstraction-based).
- PAPILLON's per-model leakage table and the cloud-only baseline were not extracted (abstract-level only).

## 4. How products decide what goes to the cloud

### Takeaway
Apple, Microsoft and Google publicly describe their hybrid designs in general terms. None of the official pages found document the routing criteria, so Halo cannot copy a published routing policy.

### Cited Findings
- Apple (Foundation Models 2025 update): the on-device model is about 3 billion parameters, quantized to 2 bits per weight with quantization-aware training, and developers can call it directly through the Foundation Models framework. The server model is a mixture-of-experts model built for Private Cloud Compute, with decoder weights at 3.56 bits per weight. [Apple ML Research](https://machinelearning.apple.com/research/apple-foundation-models-2025-updates) [measured model specs; not a routing policy]
  - The page does not say how requests are routed between on-device and PCC, or whether developers can choose. [Apple ML Research](https://machinelearning.apple.com/research/apple-foundation-models-2025-updates)
- Apple Private Cloud Compute (Apple Security Research blog): the only stated trigger is that advanced requests needing larger models go to PCC. Requests are encrypted to validated PCC node keys. A third-party OHTTP relay hides the device IP. Data is stateless ("no user data is retained in any form after the response is returned"), and production images are published for inspection against a transparency log. The post is described as an initial overview. [Apple Security blog](https://security.apple.com/blog/private-cloud-compute/) [claims]
- One secondary article (softwareseni) gives a five-model lineup and an on-device model size that do not match Apple's own documentation. Do not rely on it. [softwareseni article](https://www.softwareseni.com/which-apple-ai-workloads-leave-the-device-and-what-they-cost/) [unreliable; contradicted by Apple's own pages]
- Microsoft Phi Silica: a small transformer that runs on the NPU of Copilot+ PCs. It is exposed through a developer API, and Microsoft says it keeps language tasks on the device for latency and privacy. No routing policy to cloud was found in the official material searched. [Windows Experience Blog, Dec 2024](https://blogs.windows.com/windowsexperience/2024/12/06/phi-silica-small-but-mighty-on-device-slm/); [KB5090935](https://support.microsoft.com/help/5090935) [claim]
- Google Gemini Nano / Android AICore: Gemini Nano runs in a system service that handles model updates. Developers use the Google AI Edge SDK, which checks device support and runs inference with fallbacks. AICore has no direct internet access. [Android AICore docs](https://developer.android.com/ai/aicore?hl=hi) [official, though the search result did not show the hybrid-fallback page itself]. Community and third-party examples describe a pattern: try on-device first, then fall back to Firebase/Vertex cloud on failure. [Flutter package example](https://github.com/Piero16301/gemini_nano_android) [community, not official]

### Inferences
- The pattern that every vendor's public material implies is: on-device by default, cloud for requests the device cannot handle, with the choice made by the app or by a capability check. None of the vendors publicly document a per-request sensitivity classifier. Halo should not assume its routing policy is a copy of Apple's.
- Apple's PCC design (encrypt to attested nodes, stateless, publicly inspectable images) is a model for Halo's trust story, but Halo is a single-developer app, so it cannot run attested servers. For Halo, the equivalent guarantee is "the cloud sees only what the sanitizer emits," enforced in the native Swift layer.

### Gaps
- No vendor publicly documents the criteria used to choose between on-device and cloud execution.
- The Microsoft Phi Silica and Gemini hybrid-fallback docs were not fetched in full. Microsoft Learn and developer.android.com/ai should be checked directly before relying on the summary above.

## 5. Handing off mid-task (state transfer and failure modes)

### Takeaway
No measured study of mid-task handoff between small and large models in agent loops was found in this pass. Practical guidance here comes from the planner-executor designs above. The handoff should carry a structured, sanitized task state rather than the raw transcript.

### Cited Findings
- α-UMi shares a planner-caller-summarizer message format across the three roles, so state is passed as structured rationale plus tool calls and results. [α-UMi arXiv html](https://arxiv.org/html/2401.07324v2) [design description; no handoff failure rates reported]
- LLMCompiler passes a dependency DAG between planner and executor, which tends to make the state explicit rather than conversational. [LLMCompiler arXiv](https://arxiv.org/abs/2312.04511v2) [claim]

### Inferences
- Failure modes Halo should expect: (1) the cloud model asks for private values the sanitizer removed, then the loop stalls; (2) placeholders from the cloud plan drift from the values local tools return; (3) full-transcript handoff leaks private content in tool outputs that the sanitizer did not catch; (4) retries double-send the same request, which doubles exposure.
- Recommended handoff: a typed record with the goal, the sanitized sub-question, a list of placeholder keys with their types, and a result schema. Tool outputs stay local, and the cloud model sees only summaries it asked for.

### Gaps
- No measured failure rates for mid-task handoff were found. The failure-mode list above is an inference, not a finding.

## Implications for Halo (inferences from the sections above)
1. Local-first with a validator-gated escalation: Gemma E2B produces a tool plan, a schema/validator check decides, and only sanitized sub-questions go to DeepSeek.
2. Use PAPILLON's structure for privacy (local rewrite, cloud generate), plus a deterministic redaction layer that does not depend on the model. Measure leakage on Halo's own data.
3. Fine-tune or few-shot the local model on Halo's tool-call traces. The published small-model results depend on fine-tuning.
4. Copy TinyAgent's tool-retrieval step to keep prompts short for E2B.
5. Measure before committing: local hit rate, cloud escalation rate, leakage rate, and end-to-end latency on the real Mac app, since the published numbers are from other benchmarks.

## Source quality notes
- Several claims rely on abstract pages only: RouteLLM, PAPILLON, Confidence Tokens. Per-benchmark tables were not verified.
- Two search calls hit rate limits. The TinyAgent details were confirmed by a fetch of the arXiv HTML, but the LLMCompiler numbers come from the abstract summary only.
- AutoMix results differ across versions and should be cited with the version.
- The Apple routing details come from Apple's own pages; the softwareseni article was rejected as contradicted.
