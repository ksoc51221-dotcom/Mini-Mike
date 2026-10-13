# Margin: what a local model saves, and what it costs

Written 2026-10-09 from measurements made on this Mac (Apple M2, 16 GB), using Claude Sonnet and the local model Qwen3 8B (4-bit, via Ollama).

## The short version

- **Update, 2026-10-12: steps 1 and 2 of the recommendation are now built** (lean Claude calls, and Local mode, off until you switch it on). Graph templates are not. Every saving below is still a projection built from measured per-request numbers; Margin's new "Token Savings…" menu item will show real ones from your own use.
- **Local mode alone** (quick questions, follow-ups, short summaries and template graphs answered by Qwen3 8B) would cut Claude tokens by **about 25–50%** across the three usage profiles below, assuming 1 in 5 local answers gets re-asked on Claude.
- **Sending Claude less per call saves about as much, with no local model at all.** Dropping the screenshot and web tools from calls that don't need them cut each call's input by about half (measured). On the same profiles that is **40–42%**.
- **Both together:** about **51–60%** fewer Claude tokens.
- **What it costs:** thinner answers (judged by eye on a handful of answers), about 6 GB of your 16 GB of RAM while the model is loaded, 5.2 GB of disk, and a 6-second first load. On short tasks it is about as fast as Claude. On long text it is nearly 3 times slower.
- **What should not go local:** pronunciation (the local model got the stress right on only 3 of 20 words), free-form graphs (3 of 8 would have drawn), long summaries, fact checks, video and snips.

## What has changed so far

| | Status |
|---|---|
| Local model | **Installed.** `qwen3:8b`, 5.2 GB on disk. Ollama itself was already on your Mac. |
| Lean Claude calls | **Built, always on.** Pronounce, Visualize and Summarize on highlighted text go to Claude without the screenshot or web tools. |
| Local mode | **Built, off by default** (menu bar → Local Mode). Quick questions and short summaries are answered by the local model; everything in "What should stay on Claude" below is routed to Claude. |
| Ask Claude, labels, fall-back | **Built.** Each local answer says it was answered on your Mac and has an Ask Claude button. If Ollama isn't running, the question goes to Claude and the footnote says why. |
| Token Savings log | **Built.** The "Token Savings…" menu item. It records counts only, never text. |
| Graph templates | **Not built.** Graphs still go to Claude. |
| Lazy Claude start | **Built.** A Claude process is started at the first question rather than when the popup opens (measured: starting early gave no speed benefit), so a chat answered locally never starts one. |
| Video chats | **Left as they were.** Their transcript is most of the call, so the web tools are a small share of it, and keeping them lets you ask Claude to check a claim from the video. |
| `Benchmark.swift` | Deleted at your request. The `--benchmark` option has since been removed from `main.swift` and the README, and the project builds. |
| Test scripts | Used for the local-model tests. They live in a temporary session folder, not in the project, and will be lost. I can save them into the project if you want to re-run the tests. |

## How I measured

- **Claude numbers today:** the in-app benchmark from earlier (`BENCHMARK.md`): real Margin prompts through the real Claude process, Sonnet, 3 runs per request type. Tokens are input plus output, counting cached input in full.
- **Leaner Claude calls:** a new test with Margin's exact system prompt rebuilt from its source, 4 request types, 4 setups (with and without the screenshot, with and without the web tools), 3 runs each. Its "today" setup reproduced the app's 6.8k input tokens, so it matches the app.
- **Local model:** the same prompts sent to Claude and to Qwen3 8B side by side, 3 runs each, 8 request types, with no screenshot and web search off for both.
- **Skill tests:** 20 Russian words for stress; 8 graph requests as free-form JSON; 16 graph requests as template choices.
- **One odd result:** a single run in the lean test took 73 minutes (cause unknown). Its token counts matched the other runs, so I kept it; no timing in this report comes from that test.
- **Dollar figures** are what the Claude tool reports at API list prices. On a subscription, usage counts against your plan limit instead. I can't convert tokens to your plan's limit, so tokens are the honest unit.

## What each request costs, and what changes

Claude tokens per request (input plus output). "Lean" means no screenshot and no web tools.

| Request | Today | Lean Claude call | Local model | Local saves |
|---|--:|--:|--:|--:|
| Quick question (Simpler, Example?, Define, typed) | 6.9k ($0.014) | 3.5k ($0.005) | 0 | 100% of today |
| Follow-up in the same chat | 7.1k ($0.003) | 3.6k ($0.002) (est.) | 0 | 100% of today |
| Summarize, short passage | 7.0k ($0.015) | 3.5k ($0.005) | 0 | 100% of today |
| Summarize, 3,000 characters | 7.9k ($0.018) | 4.4k ($0.010) (est.) | 0 | 100% of today |
| Summarize, 15,000 characters | 11.0k ($0.031) | 7.5k ($0.022) (est.) | stays on Claude | none |
| Pronounce (word or sentence) | 7.1k ($0.016) | 3.6k ($0.008) | stays on Claude | none |
| Graph (Visualize) | 7.1k ($0.016) | 3.7k ($0.008) | 0 if a template fits | 100% when it fits |
| Fact check (web search) | 9.8k ($0.026) | 9.8k ($0.026) (needs the web) | stays on Claude | none |
| YouTube summary (14 min) | 10.1k ($0.032) | 8.6k ($0.027) (est.) | stays on Claude | none |

- A screenshot costs about **2.0k tokens** per call and the web tools about **1.5k**; together **3.5k**. That is why a lean call is about half the size.
- "est." rows apply those measured amounts; I measured the lean setup directly only for quick questions, pronunciation, graphs and short summaries. Lean calls gave answers of similar length, but I did not judge whether dropping the screenshot made the answers worse.
- Local model tokens don't touch your Claude limit. They cost memory and GPU time on your Mac instead.

## Savings per day, by how you might use Margin

These mixes of 100 requests a day are assumptions, not your real usage. Assumptions in the "local" columns: 1 in 5 local answers is re-asked on Claude at full price ("Ask Claude"), and 60% of graph requests fit a template.

| Requests per day | General reader | Language learner | Math and economics student |
|---|--:|--:|--:|
| Quick question (Simpler, Example?, Define, typed) | 35 | 20 | 25 |
| Follow-up in the same chat | 10 | 5 | 10 |
| Summarize, short passage | 15 | 5 | 8 |
| Summarize, 3,000 characters | 5 | 2 | 4 |
| Summarize, 15,000 characters | 10 | 3 | 3 |
| Pronounce (word or sentence) | 10 | 50 | 0 |
| Graph (Visualize) | 5 | 2 | 35 |
| Fact check (web search) | 5 | 5 | 5 |
| YouTube summary (14 min) | 5 | 8 | 10 |

### Claude tokens per day

| | General reader | Language learner | Math and economics student |
|---|--:|--:|--:|
| Today | 775k | 757k | 763k |
| Lean calls only | 455k (−41%) | 443k (−42%) | 457k (−40%) |
| Local mode only | 391k (−50%) | 570k (−25%) | 378k (−50%) |
| Local mode and lean calls | 307k (−60%) | 371k (−51%) | 306k (−60%) |

Note: the "lean" columns count YouTube summaries without the web tools (about 1.5k tokens each). As built, Margin keeps the web tools on for video chats, so the real savings from lean calls are about 1 to 2 percentage points lower than these tables show.

### Claude cost per day at API prices

| | General reader | Language learner | Math and economics student |
|---|--:|--:|--:|
| Today | $1.68 | $1.72 | $1.67 |
| Lean calls only | $0.94 (−44%) | $0.97 (−43%) | $0.99 (−41%) |
| Local mode only | $0.97 (−42%) | $1.38 (−20%) | $0.95 (−43%) |
| Local mode and lean calls | $0.75 (−55%) | $0.89 (−49%) | $0.76 (−54%) |

### If more local answers get re-asked on Claude

Re-asking costs the same Claude tokens as before, so a re-asked request saves nothing (and wastes a few seconds). Local mode alone, tokens saved:

| Re-asked on Claude | General reader | Language learner | Math and economics student |
|---|--:|--:|--:|
| 0% | 62% | 31% | 63% |
| 20% | 50% | 25% | 50% |
| 40% | 37% | 19% | 38% |
| 60% | 25% | 12% | 25% |

In dollars the savings are a little smaller than in tokens, because follow-ups and re-read (cached) input are cheap: a follow-up costs about a quarter of a first question.

The language learner saves least from a local model because most of their requests are pronunciations, which have to stay on Claude. Lean calls help them the most.

## What you give up

### Speed (same prompts, no screenshot, web search off, 3 runs)

| Request | Claude: first words / done | Local: first words / done |
|---|--:|--:|
| Quick question (Simpler, Example?, Define, typed) | 2.1s / 5.1s | 1.0s / 4.7s |
| Follow-up in the same chat | 4.5s / 7.7s | 0.6s / 5.1s |
| Summarize, short passage | 2.0s / 5.0s | 0.4s / 4.8s |
| Summarize, 3,000 characters | 1.7s / 6.3s | 1.7s / 5.8s |
| Summarize, 15,000 characters | 2.0s / 6.8s | 8.0s / 18.6s |

Caveats: the Claude side of this comparison ran while the model download was using the network, and its follow-up times varied from 3.7 to 9.9 seconds, so treat the follow-up row as roughly a tie. In the app benchmark, Claude's quick questions finished in about 4.1 seconds.

Local answers start sooner and finish about as fast on short tasks, because they are shorter (about 60–80 tokens against 130–230). The model generates about 16 tokens a second. The first request after a pause also waits about 6 seconds while the model loads. Long text is where it falls behind.

### Quality (the same prompt to both, answers compared by eye)

- **Simple explanations:** fine, but shorter and with less detail.
- **Define terms:** the local answer covered 3 of the passage's 6 terms and added an unrelated $10 movie example. Claude defined all 6.
- **Keywords:** 5 items against Claude's 7.
- **Long text (15,000 characters):** the local list was generic and missed the features that matter (snips, shortcuts, corner circles). Claude's picked those.
- I judged these myself on a handful of answers. It is not a scored test.

### Risks

- **Routing guesses.** Margin has to guess whether a typed question needs facts or the web. A wrong guess gives a confident local answer that was never checked. The Ask Claude button is the safety net, and I would route obvious cases ("check", "latest", "is that accurate") to Claude by keyword.
- **No screenshot for local answers.** The local model can't see images, so "what is this button?" style questions would need Claude. It still gets the highlighted text and the text around it.
- **The 20% re-ask rate is a guess.** If you re-ask more often, the savings shrink, as the table above shows.

### Your Mac

- **Memory:** 5.9–6.2 GB while the model is loaded, out of 16 GB. It runs entirely on the GPU, and unloads itself after 5 idle minutes.
- **Disk:** 5.2 GB.
- **Battery and heat:** not measured.

## What should stay on Claude, and why

| Request | Test result with the local model |
|---|---|
| Pronunciation | Stress marked correctly on **3 of 20** Russian words, about what guessing gives. The voice follows the stress it is given, so a wrong answer teaches a wrong pronunciation. |
| Graphs written as free-form JSON | Only **3 of 8** would have drawn cleanly (broken JSON or no graph), and each took 9–21 seconds. |
| Graphs by picking a template | Right template and numbers on **14 of 16**, in 1–2 seconds each. The 2 misses were a vague highlight with no numbers, which would fall back to Claude. Only graphs that fit the template menu would run locally. |
| Long summaries | 18.6 seconds against 6.8, and missed the main features. |
| Fact checks | The local model has no web search. |
| Video summaries | Not tested locally. A 14-minute transcript is about as long as the 15,000-character text that took 18.6 seconds and missed the key points, and an hour-long video is several times longer. |
| Snips | The local model can't read images. |

## Recommendation

In this order, because each step is safer and bigger than the next:

1. **Lean Claude calls.** No screenshot or web tools for pronunciation, graphs and summaries, where the highlighted text is the whole question. About half the input per call, no local model, and no change in where answers come from. The one thing I have not checked is whether answers get worse without the screenshot.
2. **Local mode, off by default.** Quick questions, follow-ups and short summaries, with an "Ask Claude" button on every local answer, a label on which model answered, and an automatic fall back to Claude if Ollama isn't running.
3. **Graph templates**, handled locally, with everything else going to Claude.

The biggest unknown is your real usage. I can add a small log to Margin that records each request's type and tokens, so after a week we'd have your actual mix instead of the three assumed ones above.
