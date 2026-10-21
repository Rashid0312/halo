# Inference-time techniques for small-model tool calling (1-8B, no retraining)

Scope note: evidence below is from web search and page fetches run on 2026-10-21. Where a claim comes from a vendor page, a secondary summary, or a snippet I did not open, it is labelled. Halo-specific numbers (M1, 5,800-token prompt, 450-900 tok/s prompt processing) are the user's own and are not re-measured here.

## Constrained / grammar-guided decoding for tool calls

### Takeaway
Constraints reliably guarantee valid JSON and schema shape for small models, but for small models they can cut semantic correctness (wrong tool or wrong argument values) when the schema is applied hard to the answer. The best-supported pattern is to let the model reason freely and constrain late, or to constrain only the tool-name and argument skeleton.

### Cited Findings
- Across about 15,000 generations on Qwen2.5-0.5B, Qwen2.5-1.5B and SmolLM2-1.7B, hard answer-only schema decoding raised schema validity from 61.5% to 100.0%, but cut answer accuracy from 19.7% to 11.0%. Wrong-but-valid-schema outputs were 88.9% of constrained outputs versus 49.5% unconstrained — [The Constraint Tax, arXiv 2605.26128](https://arxiv.org/abs/2605.26128) (abstract only; read via the abstract page)
- On a calendar tool-call task with Qwen2.5-1.5B, prompt-only JSON reached 91.5% executable accuracy, while the hard tool-call schema reached 48.0% (both at 100% schema validity) — [The Constraint Tax, arXiv 2605.26128](https://arxiv.org/abs/2605.26128)
- The authors say the errors are semantic rather than structural, and that the Qwen results replicated across vLLM and SGLang while SmolLM2 changed between engines — [The Constraint Tax, arXiv 2605.26128](https://arxiv.org/abs/2605.26128); engine-dependence noted in a search summary, not verified in the full paper.
- The same paper proposes "delayed packaging" (free reasoning first, constraint applied late) as a design pattern, but gives no numbers for it in the abstract — [The Constraint Tax, arXiv 2605.26128](https://arxiv.org/abs/2605.26128)
- A companion paper tests 0.6B-4B models (Qwen3, Llama 3.2, Phi-4-mini) on 14 structured-output tasks, three of them function-calling. Its title says constrained decoding "eliminates structural failures" but "reveals a scale-dependent semantic gap" — [arXiv 2609.23742](https://arxiv.org/pdf/2609.23742). I did not open the results; treat the headline as the only finding.
- StructureBench (IJCAI 2026) reports that constrained decoding guarantees syntax but does not necessarily improve semantic accuracy; it is more optimistic that it helps well-defined tool-call schemas — [IJCAI 2026 proceedings](https://www.ijcai.org/proceedings/2026/0267.pdf) (search snippet only, not opened).
- MLX support: MLX itself does not enforce schemas. The LM Studio post says the Outlines package supports the mlx_lm runtime and converts a JSON schema to a regex — [LM Studio MLX engine](https://lmstudio.ai/mlx) (vendor post). An aggregator page says the same about MLX having no built-in schema enforcement — [Emergent Mind](https://www.emergentmind.com/topics/mlx) (secondary). vllm-mlx ships a JSONSchemaLogitsProcessor — [vllm-mlx docs](https://vllm-mlx.is-a.dev/reference/api/vllm_mlx/constrained/) (project docs, not mlx-lm).
- XGrammar has an MLX-capable backend (inferred from an Outlines patch that accepts a tensor library name "mlx") — [XGrammar paper](https://arxiv.org/pdf/2411.15100). Its headline 100x / 80x speedups are against older methods on GPU, not Apple Silicon.
- Per-step mask cost, one trie-automata paper on Qwen3-8B with enum schemas: LLGuidance 73-141 us per step, XGrammar 5.4-9.5 us — [Trie Automata, arXiv 2608.12574](https://arxiv.org/pdf/2608.12574). A parser-stack paper reports very different XGrammar numbers on JSON schemas (26,000-54,000 us per token) and calls them into question — [arXiv 2608.03065](https://arxiv.org/pdf/2608.03065). The two disagree by orders of magnitude; do not rely on either without a local benchmark.
- llguidance project page claims about 50 us per token with no significant startup cost — [llguidance on SourcePulse](https://www.sourcepulse.org/projects/1844423) (project claim).

### Inferences
- For Halo, the measured risk is that a hard schema over the whole answer lowers tool-choice accuracy on 1-2B-class models. A safer design is: free text or a tool-name-only constraint (an enum of the tool names that are in the retrieved subset), with argument JSON validated after generation and retried on failure.
- A tool-name enum is cheap to enforce: it is a small finite set, so per-step masks are tiny. Argument schemas are where semantic loss is most likely.
- Per-token masking cost is likely small relative to a 450-900 tok/s prefill, but the disagreement between sources means the overhead needs a local timing run before adopting any engine.
- For mlx-lm, the practical path is Outlines (regex/JSON-schema masking). Whether mlx-lm itself exposes a logits-processor hook that accepts a constraint was not confirmed; check the mlx-lm `generate` API and source directly.

### Gaps
- No measured result found for an MLX or Apple Silicon constrained-decoding run on a tool-calling benchmark.
- Could not confirm mlx-lm's native logits-processor API (the MLX docs and repo were not in the search results).
- Could not confirm the Outlines MLX integration's API or usage example.
- Results found are for 0.5-1.7B Qwen/SmolLM models; I found no 3-8B tool-calling constrained-decoding result.

## Tool retrieval / tool selection

### Takeaway
Retrieving a small subset of tools per request is the best-measured technique here. TinyAgent's fine-tuned DeBERTa retriever cut the tool-definition prompt by about half and raised success rate for both its 1.1B and 7B models, though it required training a retriever. Plain top-k retrieval lowered success.

### Cited Findings
- TinyAgent Table 1 (ToolRAG, 16 tools total): no retrieval (all tools) had 2,762 prompt tokens with success 78.89% (1.1B) and 83.09% (7B); basic RAG had 1,674 tokens with 74.88% and 78.50%; fine-tuned DeBERTa-v3-small had 1,397 tokens with 80.06% and 84.95%. Tool recall: 1.0 / 0.949 / 0.998 — [TinyAgent, arXiv 2409.00608](https://arxiv.org/pdf/2409.00608) (values from the HTML version at arxiv.org/html/2409.00608v2)
- The DeBERTa retriever is a 16-way multi-label classifier with sigmoid, keeping tools above 50% probability, averaging 3.97 tools per query versus 6 for basic RAG — [TinyAgent, arXiv 2409.00608](https://arxiv.org/html/2409.00608v2)
- The paper's own text says basic RAG uses top-6 (recall 0.968), but its Table 1 caption says top-3 (recall 0.949). The paper does not reconcile this — [TinyAgent, arXiv 2409.00608](https://arxiv.org/html/2409.00608v2)
- Latency and size (TinyAgent Table 2, end-to-end planner latency including prompt processing; hardware not stated in the table): 1.1B at 16-bit 3.9 s, 4-bit 2.9 s; 7B at 16-bit 19.5 s, 4-bit 13.1 s — [TinyAgent, arXiv 2409.00608](https://arxiv.org/html/2409.00608v2). Hardware is not tied to the table, so do not transfer these numbers to the M1 directly.
- The TinyAgent GitHub and dataset are open — [SqueezeAILab/TinyAgent](https://github.com/SqueezeAILab/TinyAgent).
- Gorilla's retriever-aware approach appends retrieved API documentation to the prompt at inference time, but I did not retrieve its numbers from the paper. A secondary blog's "78% to 11% hallucination" figure is unverified — [Gorilla blog](https://gorilla.cs.berkeley.edu/blogs/1_gorilla_intro.html) (project claim; secondary figure from beancount.io, not checked).
- TinyAgent's 1.1B/7B models are fine-tuned, so the retrieval result is not "no training" for the model. The retriever itself is also trained. The gain for an untrained model with a non-learned retriever (e.g. embedding similarity) was not measured in what I read.

### Inferences
- For Halo's ~40 tools (~5,800 tokens with system prompt), a retrieval step that keeps 4-8 tools would cut the tool-definition block roughly in half, based on TinyAgent's ratio. At 450-900 tok/s that saves on the order of several seconds per turn, before any caching effect.
- Retrieval needs a fallback: the TinyAgent paper's own motivation is that auxiliary tools are often needed and simple similarity misses them. A cheap design is to always include a fixed core set (e.g. search, read page, answer) plus retrieved tools.
- Retrieval can be done without training using a sentence embedding or keyword match over tool descriptions. That variant was not measured in the sources I read, so it should be benchmarked against Halo's own tool-call eval.

### Gaps
- No measured result for untrained, embedding-only tool retrieval on a small model (the most relevant variant for Halo).
- Could not read Gorilla's retrieval experiments; the only numbers are from secondary sources.
- The TinyAgent latency table does not state the hardware.

## Few-shot / retrieved in-context examples for tool use

### Takeaway
I did not find a measured study on this for 1-8B models in the time available. Treat few-shot examples as an untested option that adds prompt tokens, which are the bottleneck on Halo.

### Cited Findings
- BFCL-based comparison: for some small models (Llama-3.1-8B-Instruct, Llama-3.2-3B-Instruct) a naive serialization of the function spec in the prompt beat the model's native tool-call parser on accuracy — [EngGPT2 benchmark, arXiv 2605.07731](https://arxiv.org/pdf/2605.07731). This is about prompt format, not examples.
- Phi-4 Mini on BFCL Non-Live Simple: 67.9% with prompt-based calling versus 38.0% with native calling; Qwen-3 0.6B and 1.7B were within a few points of each other — [Small Reasoning Models are Instruction Followers in Function Calling, arXiv 2608.22472](https://arxiv.org/pdf/2608.22472) (search snippet; table not opened in full).
- A small edit to the default BFCL system prompt substantially changed multi-turn scores for Qwen3-4B and 8B, so prompt format alone can move results — [arXiv 2606.00135](https://arxiv.org/pdf/2606.00135).

### Inferences
- Because prompt format alone can swing small-model results by tens of points, Halo should compare its own tool-call prompt templates (native tool-definition block vs. plain-text function spec) on its own eval before adding examples.
- A single worked example of a correct call is likely to cost on the order of 100-300 tokens per example, which is non-trivial against a 5,800-token prompt. Retrieving examples only for the matched tools would keep this small.

### Gaps
- No measured study found of few-shot or retrieved examples for tool-call accuracy on 1-8B models.
- Did not find token-cost or latency data for example retrieval.

## Compact observation formats (web/desktop agents)

### Takeaway
Candidate ranking and DOM pruning reduce page observations by one to two orders of magnitude in the papers I found, but the strongest numbers come from larger or specialised pipelines. No clean measured result for a small model reading an accessibility tree versus a ranked candidate list was found.

### Cited Findings
- MindAct / Mind2Web: a fine-tuned small LM ranks page elements, and a larger LM picks the action from a short multiple-choice list — [Mind2Web, arXiv 2306.06070](https://arxiv.org/pdf/2306.06070); candidate format as used in AgentBench — [AgentBench, arXiv 2308.03688](https://arxiv.org/pdf/2308.03688)
- Prune4Web (2025): programmatic DOM pruning reduces candidate elements by 25-50x and raises low-level grounding accuracy from 46.8% to 88.28% — [Prune4Web, arXiv 2511.21398](https://arxiv.org/html/2511.21398v1) (author-reported; not independently checked)
- Agent-E: flexible DOM distillation in which the browser agent picks the DOM representation suited to the task; reports 73.2% on WebVoyager — [Agent-E, NeurIPS 2024 listing](https://neurips.cc/virtual/2024/100935). Emergence says a compact state representation would allow smaller local LLMs, but I found no published evaluation of a small model on this — [Emergence blog](https://www.emergence.ai/blog/uacc2lfygofrtetmwtdr3l6nblfs3t)
- A commercial vendor page compares an accessibility-tree snapshot of about 18,000 tokens with a ranked snapshot of about 800 tokens — [Predicate Systems skill page](https://skillsmp.com/creators/predicatesystems/openclaw-predicate-skill/skill). Vendor claim; treat as an order-of-magnitude illustration only.

### Inferences
- For Halo's "find X on page" case, the most transferable pattern is: extract a page's text once, then run a targeted extraction over the text with a small model, returning only the matched span. This keeps the 3-4k token page text out of the main agent's context. This is an inference from the candidate-ranking literature, not a measured result for the tool-result case.
- Ranking can be done with a cheap heuristic (keyword / embedding match of the query against text blocks) before any model call.

### Gaps
- No measured result found for small-model "find X on page" extraction on long tool results.
- No WebArena accessibility-tree vs. set-of-mark comparison for small models was retrieved.
- browser-use's own evaluation numbers were not retrieved.

## Prompt / KV caching and context management

### Takeaway
MLX and mlx-lm support prompt caches saved to disk and bounded KV caches, which should cut repeated prefill of the fixed ~5,800-token system-plus-tools prefix. I found no published mlx-lm measurement of this on Apple Silicon.

### Cited Findings
- mlx-lm prompt cache: built with `make_prompt_cache`, saved to disk and reloaded, with a `max_kv_size` option that caps the cache — [third-party skill page, openskillindex.com](https://openskillindex.com/skills/plurigrid-asi-mlx-apple-silicon) (secondary; check against mlx-lm docs)
- MLX has a rotating KV cache with a configurable window and on-disk prompt caching — [Production-Grade Local LLM Inference on Apple Silicon, arXiv 2511.05502](https://arxiv.org/pdf/2511.05502). No throughput figures for the caching in that paper.
- vllm-mlx reports 5.8x speedup on shared-prefix prompts and 42 ms time-to-first-token on a cache hit for a 512-token shared prefix — [vllm-mlx documentation summary](https://www.emergentmind.com/topics/vllm-mlx) (secondary; vllm-mlx, not mlx-lm)
- LM Studio's MLX engine checkpoints KV caches at 256-token boundaries so edited or rewound conversations can reuse prefixes; it reports up to 2x throughput on repeated long-context agentic workflows — [LM Studio mlx-engine post](https://lmstudio.ai/blog/mlx-engine-agentic-workloads) (vendor claim)

### Inferences
- The ~5,800-token fixed prefix should be cached once per session. If retrieval changes the tool set per turn, the cached prefix is lost, so retrieval and caching conflict. Put the stable part (system prompt, core tools) first and the retrieved tools after it, so that the cached prefix is the stable part.
- Trimming old tool results and replacing them with short summaries keeps the prompt from growing; this is standard practice but I found no small-model measurement.

### Gaps
- No mlx-lm tokens/s benchmark with prompt-cache reuse found.
- No measurement found of summarising tool results for small models.

## Self-verification, validator-error retries, reflection

### Takeaway
At small scale, intrinsic self-correction and prompt-only reflection tend to hurt or give little gain. Feedback from an external signal (a validator error, a tool result) is the case that is more likely to help, and it is best measured on a trained or structured setup.

### Cited Findings
- Small models with no external verifier: Self-Refine dropped accuracy from 43.8% to 38.2% in one code-generation table, while simple prompting rose slightly — [Self-Correcting Code Generation Using Small Language Models, arXiv 2505.23060](https://arxiv.org/pdf/2505.23060)
- Prompt-based reflection helps large LLMs more than small ones, which show minor gains or degradation, attributed to low-quality reflections — [ReflectEvo, arXiv 2505.16475](https://arxiv.org/pdf/2505.16475)
- Small models can learn self-correction from self-generated trajectories, but this was tested on QA, not tool calling — [arXiv 2503.08681](https://export.arxiv.org/pdf/2503.08681)
- In multi-turn tool use, prompt-based reflection is fragile: after a failed call, models tend to repeat the mistake. A 2025 paper proposes training reflection and reports gains on BFCL v3 and Tool-Reflection-Bench — [Failure Makes the Agent Stronger, arXiv 2509.18847](https://arxiv.org/html/2509.18847v2). The gains require training.

### Inferences
- A validator-error retry (JSON parse fails, or a tool name is not in the list) is a deterministic external signal and is unlikely to hurt, but it should be capped at one retry. Asking the model to "reflect" on a correct call is the pattern the sources suggest hurts small models.
- For Halo, retries should re-prompt with the exact validator message, not a generic "think again".

### Gaps
- No direct measurement found of validator-error retries on 1-8B tool-calling models.
- No study found on whether reflection hurts small-model tool calls when no tool result is given.

## Reducing "announcing instead of acting" and premature clarification

### Takeaway
The only concrete evidence found is that a custom handoff prompt asking for a structured tool call instead of text fixed a text-instead-of-call failure in one community report. Premature clarification was not covered by any source I found.

### Cited Findings
- A LlamaIndex thread reports an agent writing "I am handing off" as plain text instead of a tool call, fixed by a prompt that tells the model to emit the structured JSON call instead — [LlamaIndex community thread](https://community.llamaindex.ai/instructing-an-llm-to-send-tool-calls-instead-of-messages-Xr67DcgWpXWh) (anecdotal)
- A GitHub issue shows models describing tool use and fabricating results when the tools were never passed to the API. The fix was at the code level, not the prompt — [cleveragents issue #59](https://git.cleverthis.com/cleveragents/cleveractors-core/issues/59) (anecdotal)
- On BFCL, native tool-call parsing vs. prompt-based calling changes results substantially by model family (see the few-shot section) — [arXiv 2608.22472](https://arxiv.org/pdf/2608.22472)

### Inferences
- First check that tools are actually being sent through the native tools parameter on every turn. Announcing-instead-of-acting is a plausible symptom of tool definitions missing or being truncated in the prompt.
- Prompt rules that have a basis in the sources: state that tool calls must be emitted, not described; and say to call a tool when required arguments are inferable from context, asking only if a required argument is missing. The second rule is my suggestion and is not supported by a measured result here.

### Gaps
- No measured result for clarification-question rates in small models.
- No ablation of prompt wording for "announce vs. act" found.

## Suggested next steps for Halo (in priority order)

1. Run a local eval on Halo's own tool-call set with three conditions: all 40 tools; embedding-retrieved 4-8 tools plus core set; and a tool-name enum constraint. Report tool-choice accuracy, argument validity and latency separately (per the Constraint Tax recommendation).
2. Time a constrained-decoding step on MLX with Outlines (or a logits processor) on a single tool-call turn before choosing an engine; the sources disagree on mask cost by about three orders of magnitude.
3. Keep the stable prefix (system prompt and core tools) first and cache it; check mlx-lm's `make_prompt_cache` on a real session to measure the prefill saved.
4. Add a single capped retry on JSON or tool-name validation failure, with the exact validator message. Do not add open-ended reflection without measuring it.
5. For web pages, add a targeted extraction step over stored page text so that 3-4k tokens of page text do not enter the main context.
