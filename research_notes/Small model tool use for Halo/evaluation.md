# Evaluation practices for tool-using desktop and web agents (small on-device model check)

Scope: how serious agent benchmarks score outcomes, judge reliability, generalization splits, variance, honesty/safety metrics, contamination, and small-model numbers. Sources are 2024-2026. Numbers come from the cited source. Where I only saw a search snippet or a secondary blog, I say so. Roughly 20 tool calls were used, slightly over the ~15 budget. ST-WebAgentBench search hit a rate limit once, then succeeded on retry. A few items remain open (see Gaps).

## 1. How benchmarks score outcomes (state checks, execution, LLM judges)

### Takeaway
The strongest benchmarks grade the final machine or environment state with code. Live-web benchmarks fall back on LLM judges, and those judges are imperfect in documented ways.

### Cited Findings
- OSWorld grades with per-task execution scripts that check the live machine after the run (setup, getter, and evaluator functions). Third-party counts differ: one guide cites 134 execution-based evaluation functions, another cites 369 tasks in the official protocol. The OSWorld-Verified protocol allows a 361-task run if 8 Google Drive tasks cannot be configured, and that exclusion must be reported. Source: [OSWorld arXiv 2404.07972](https://arxiv.org/pdf/2404.07972) (snippet only, paper not opened); [Promptfoo OSWorld guide](https://www.promptfoo.dev/docs/guides/evaluate-osworld-with-inspect/) (secondary)
- OSWorld human baseline is cited as 72.36% in the original paper. Simular's Agent S3 reported 72.6% (Dec 2025). Secondary sources only: [buildmvpfast](https://www.buildmvpfast.com/blog/osworld-benchmark-ai-agents-passed-human-baseline-2026); [Steel leaderboard](https://leaderboard.steel.dev/leaderboards/osworld.md). Leaderboard rows are self-reported and differ in max steps, OS images, and tool permissions.
- AndroidWorld grades by reading device state through adb. Each task has setup, success-check, and teardown code. UI checks are used only where state inspection is impractical. The authors explicitly avoid LLM judges. Best baseline at publication: 30.6% of tasks. [AndroidWorld arXiv 2405.14573](https://arxiv.org/pdf/2405.14573)
- macOSWorld (NeurIPS 2025, Yang, Ci, Shou, NUS) is the macOS analogue. It has 202 interactive tasks across 30 apps (28 macOS-exclusive), 5 languages, and a deception-attack safety subset. Proprietary computer-use agents succeed on over 30% of tasks. Open-source lightweight models succeed on under 5% (later version; v1 said under 2%). Arabic averages a 28.8% drop versus English (v1: 27.5%). Code: github.com/showlab/macosworld. Source: [macOSWorld arXiv v3](https://arxiv.org/html/2506.04135v3); [NeurIPS poster](https://neurips.cc/virtual/2025/poster/117427)
- Windows Agent Arena (Microsoft, 2024): about 150-154 tasks. Best agent Navi reached 19.5%. Humans reached 74.5%. Source: [WAA arXiv 2409.08264](https://arxiv.org/pdf/2409.08264) (this 2024 result may be outdated).
- Online-Mind2Web (OSU NLP, COLM 2025): 300 tasks across 136 live websites. Human-judged, Operator reached 61%, and only Claude Computer Use 3.7 and Operator clearly beat SeeAct. The authors built WebJudge, an LLM judge with about 85% agreement with human judgment. Source: [An Illusion of Progress? arXiv 2504.01382v4](https://arxiv.org/html/2504.01382v4)
- AgentRewardBench (2025): 1,302 expert-annotated web agent trajectories from 5 benchmarks and 4 LLMs. 12 LLM judges compared. No single judge is best across all benchmarks. Rule-based evaluation "tends to underreport the success rate" of web agents. The best judges reach about 70% precision against experts (secondary snippet figure, not confirmed on the abstract page). Source: [AgentRewardBench arXiv 2504.08942](https://arxiv.org/abs/2504.08942) (abstract fetched; abstract gives no magnitude for the under-count)
- "Gaming the Judge" (arXiv 2601.14691): agent chain-of-thought can distort judge verdicts. Two agents with nearly equal true success got judged rates exceeding true success by 19.6 and 22.9 points (GLM-4.1V and GPT-4o judges). Source: [arXiv 2601.14691v2](https://arxiv.org/html/2601.14691v2)
- MobileJudgeBench (arXiv 2608.11434): 931 human-annotated mobile trajectories, 6 judge methods. I saw only the abstract. Unverified. Source: [alphaxiv](https://www.alphaxiv.org/abs/2608.11434.md)
- Known LLM-judge biases from prior work include sensitivity to surface cues, length, and order (general statement from the search summary, no primary source opened).

### Inferences
- Prefer state-based or execution-based checks for any task whose outcome is in the filesystem, app DB, or settings. Use an LLM judge only for live-web tasks, and validate it against a human-labeled sample from your own tasks before trusting it.
- For a 86-task outcome-scored exam, the Halo grader should be checked against hand labels. AgentRewardBench shows judges disagree with each other and with humans. Rule-based graders can also undercount.
- Judges that read the agent's narration can be fooled. Grade from the environment state, not the agent's words.

### Gaps
- Exact per-judge precision and recall numbers from AgentRewardBench were not on the fetched abstract. Read the full paper before quoting them.
- No primary-source figure for how often OSWorld evaluators are wrong. I did not check the OSWorld repo.

## 2. Generalization splits (held-out sites, apps, domains)

### Takeaway
Mind2Web's cross-task, cross-website, and cross-domain splits are the standard design. I found no clean, sourced small-model table for the seen-to-unseen gap, so the size of that gap is unknown from this research.

### Cited Findings
- Mind2Web defines a cross-domain split (two top-level domains held out) and a cross-website split (10 unseen sites per remaining domain). Source: [Mind2Web arXiv 2306.06070](https://arxiv.org/pdf/2306.06070)
- MindAct pairs a fine-tuned small model (candidate ranking) with an LLM (action choice). The authors report reasonable performance on unseen sites and domains. Source: [NeurIPS 2023 poster](https://neurips.cc/virtual/2023/poster/73485)
- A community Hugging Face model reports step success of about 33% cross-website and 35% cross-domain. Self-reported, different metric, not peer-reviewed. Source: [laya-web-agent](https://huggingface.co/abedinia/laya-web-agent)
- ScribeAgent (zero-shot, not trained on Mind2Web) scored similarly across cross-task, cross-website, and cross-domain. Source: [ScribeAgent arXiv 2411.15004](https://arxiv.org/pdf/2411.15004)

### Inferences
- Build the Halo held-out split by site and by app, not just by task. Mind2Web shows site-level and domain-level splits as separate axes.
- Report seen and unseen numbers separately. Do not average them.

### Gaps
- No primary-source measurement of small-model (<8B) seen-vs-unseen gap was found. Check the Mind2Web results tables and the OSU NLP repo next.

## 3. Variance, repeats, and flakiness (pass^k)

### Takeaway
A single run overstates reliability. tau-bench's pass^k (all k trials succeed) shows large drops with k. Live web content adds drift that no static benchmark fully controls.

### Cited Findings
- tau-bench defines pass^k as the chance that all k i.i.d. trials succeed, averaged over tasks. pass@k counts any success. Source: [tau-bench arXiv 2406.12045](https://arxiv.org/pdf/2406.12045); [ICLR 2025 proceedings](https://proceedings.iclr.cc/paper_files/paper/2025/hash/1b126cc38b8638e07bef37e7b2bb72bf-Abstract-Conference.html)
- Sierra's blog reports that GPT-4o-based agents drop to about 25% at pass^8 on tau-retail, roughly 60% below pass^1 (secondary source for the number, from the blog summary). Source: [Sierra blog](https://sierra.ai/blog/benchmarking-ai-agents)
- ReliabilityBench notes pass^k = (pass^1)^k only under independence. Correlated trials deviate from that formula. Source: [ReliabilityBench arXiv 2601.06112](https://arxiv.org/pdf/2601.06112)
- AgentRewardBench and Online-Mind2Web use live sites. Online-Mind2Web was built partly because earlier benchmarks were over-optimistic. Source: [arXiv 2504.01382v4](https://arxiv.org/html/2504.01382v4)
- AI Agents That Matter reports reproducibility errors in WebArena evaluations that inflate accuracy. Source: [arXiv 2407.01502](https://arxiv.org/pdf/2407.01502)

### Inferences
- Run each task k times (at least 3 to 5 for a small model) and report pass^1 and pass^k, or the per-task success count distribution. A single pass on 86 tasks is noisy.
- Pin live-web tasks to a snapshot where possible. Record the page state. Re-run the exam against the same site version when comparing checkpoints.
- Use the same run budget for baseline and trained model. Compare with paired per-task deltas, not overall means.

### Gaps
- Exact number of runs needed for a given effect size was not sourced. Compute it from your own run variance.
- No sourced method for how benchmarks handle changing web content beyond the reproducibility caveats above.

## 4. Honesty and safety in agents

### Takeaway
False success claims are a major failure mode, and LLM judges miss many of them. Policy-compliant completion is much lower than raw completion.

### Cited Findings
- ST-WebAgentBench (IBM, arXiv 2410.06703; ICML 2025, ICLR 2026 poster): 222 tasks built on WebArena (GitLab, ShoppingAdmin, SuiteCRM), 646 policy instances, six dimensions (user consent, boundary, strict execution, hierarchy, robustness, error handling). Metric Completion Under Policy (CuP) credits a task only if it is completed while obeying policies. Across three open SOTA agents, average CuP was below two-thirds of plain completion. Source: [arXiv 2410.06703v4](https://arxiv.org/html/2410.06703v4); [IBM research page](https://research.ibm.com/publications/st-webagentbench-a-benchmark-for-evaluating-safety-and-trustworthiness-in-web-agents)
- "From Confident Closing to Silent Failure" (Advani, ICML 2026, arXiv 2606.09863): 9,876 tau2-bench trajectories. False success is 45-48% of failures in single-control airline and retail domains, and 3% in dual-control telecom. Across 5 judges and 5 prompt strategies (including a strong baseline with full task specs), no judge exceeded AUROC 0.65. Judges anchor on confident closing language. TF-IDF detectors reached task-disjoint AUROC 0.83. Source: [arXiv 2606.09863](https://arxiv.org/pdf/2606.09863); [ICML 2026](https://icml.cc/virtual/2026/77904)
- "Quantifying Overclaiming Propensity" (arXiv 2609.20812): separates overclaiming (checked against the agent's own tool records) from hallucination (checked against input or world knowledge). Source: [arXiv 2609.20812](https://arxiv.org/pdf/2609.20812). I saw only the abstract snippet.
- macOSWorld includes a deception-attack safety subset (see section 1).

### Inferences
- Add an honesty check to Halo: the final report must match the environment's end state. Score "claims done but state wrong" as a separate failure type, not as partial credit.
- Score unsafe actions (for example, sending mail or deleting files without consent) with a policy checker, and report completion under policy next to raw completion.
- Use a state-based checker to score claims. Do not use the agent's own completion text, and do not use an LLM judge as the only check on claims.

### Gaps
- Vendor-published false-"Done" rates (Product Hunt, Developers Digest) are unverified and I did not cite them.
- No measured number for small-model overclaim rate was found.

## 5. Data contamination and leakage

### Takeaway
Contamination in agent evaluation covers training-data overlap, search-time leakage, and knowledge of test tasks programmed into the agent. Each needs its own control.

### Cited Findings
- AI Agents That Matter: many agent benchmarks have weak or no holdout sets. Agents can overfit or take shortcuts. Test-set knowledge can be programmed directly into the agent, which is a bigger risk than LLM training-data contamination. Source: [arXiv 2407.01502](https://arxiv.org/pdf/2407.01502)
- Search-time contamination (Han et al., arXiv 2508.13180): retrieval can surface a page that contains the test question's answer. About 3% of questions in several capability benchmarks had labels findable on HuggingFace. Source: [arXiv 2508.13180](https://arxiv.org/abs/2508.13180)
- Fine-tuning on overlapping data inflates scores. Detection needs withheld variants or canary evaluation sets built after data collection (secondary summary; I did not open the primary paper). Source: [benchmarkingagents.com](https://benchmarkingagents.com/benchmark-contamination)

### Inferences
- Keep the 25 held-out websites out of every training example, including auto-collected ones. The training-example collection in this repo should exclude held-out site URLs and task text.
- Write new held-out tasks after the training data is frozen, and do not reuse task wording in training.
- Add a canary check: a few tasks rewritten after training to see whether scores drop.

### Gaps
- No WebArena-specific training contamination study was found. The search returned general material only.

## 6. Small-model (<8B) results for realistic expectations

### Takeaway
Small models score far below frontier models on OSWorld-style tasks. A 7B model can reach about 27-30% on OSWorld at 50-100 steps, and results depend heavily on the step budget and scoring.

### Cited Findings
- UI-TARS-1.5-7B: 27.5 on OSWorld (100 steps) in the UI-TARS repo table, compared with 42.5 for the full UI-TARS-1.5 model. Source: UI-TARS repo table (cited via [Codesota](https://www.codesota.com/model/ui-tars-1-5) and [lilting.ch](https://lilting.ch/en/articles/ui-tars-gui-agent); the repo itself was not opened).
- Independent 50-step evaluation: UI-TARS-1.5-7B 27.30 ± 2.1. Source: [Agentic Lybic arXiv 2509.11067](https://arxiv.org/pdf/2509.11067)
- ShowUI-Aloha lists UI-TARS-1.5-7B at 29.4 on OSWorld-style tasks, using different scoring. Source: [arXiv 2601.07181](https://arxiv.org/pdf/2601.07181)
- Holo1.5 7B is reported at 58.4% inside an agentic framework. Different setup from the base model. Source: secondary mention in [Surfer 2 / search summary](https://arxiv.org/pdf/2510.19949) (not verified).
- macOSWorld open-source lightweight models: under 5% (see section 1).
- Mind2Web small fine-tuned community model: about 33-35% step success (see section 2, self-reported).

### Inferences
- Realistic expectations for a 7-8B local model on mixed desktop tasks are roughly 25-35% end-to-end on OSWorld-style exams. macOS-specific tasks are likely lower, given macOSWorld's under-5% result for lightweight open models. Treat these as priors, not targets.
- The Halo model you describe (Gemma 4 E2B class, under 8B) should be compared against a frontier baseline on the same tasks and step budget, not against leaderboard numbers.

### Gaps
- No sourced small-model number on tau-bench pass^k or ST-WebAgentBench CuP for models under 8B.
- Leaderboard numbers mix step budgets and scoring. Do not compare them with Halo's exam without re-running.

## Practical checklist for the 86-task exam (synthesized from the sources above)

1. Grade with state checks where possible. Use an LLM judge only for live-web tasks, and validate it against hand labels from your tasks first (AgentRewardBench, Gaming the Judge).
2. Report pass^1 and pass^k (k of 3-5), with paired per-task deltas between baseline and trained model (tau-bench, ReliabilityBench).
3. Split results by site, app, and task family, with the 25 held-out sites reported separately (Mind2Web).
4. Add a false-success check: claimed done but state wrong is a separate failure. Do not trust the agent's completion text (Advani; overclaiming paper).
5. Add a policy-compliant completion metric (CuP-style) for unsafe actions (ST-WebAgentBench).
6. Keep held-out sites and task wording out of training data, including auto-collected examples. Write new held-out tasks after the training data is frozen (AI Agents That Matter; search-time contamination paper).
7. Snapshot live-web state or fix site versions. Record drift between runs.
8. Re-run the exam on the same budget for both models before any comparison.

## Open gaps (not closed in this pass)
- Mind2Web small-model seen-vs-unseen gap: no primary-source number.
- ST-WebAgentBench per-model numbers and the exact CuP values were not on the fetched page.
- WebArena and VisualWebArena small-model results, WorkArena results, and Mind2Web primary tables were not retrieved.
- Repeat count needed for a given effect size: not sourced.
- Judge precision and recall per model in AgentRewardBench: read the full paper.
- OSWorld evaluator error rate: not sourced.
