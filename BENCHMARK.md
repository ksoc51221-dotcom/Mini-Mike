# Margin benchmark, 2026-10-09

Measured with a `--benchmark` option (since removed from Margin): every kind of request Margin makes, through its real prompts and the
real `claude` process, 3 runs each, on the same Mac. 114 Claude turns in all (about $2.12 at API list prices).

**What to know when reading it**
- The screenshot is a synthetic page of text at Margin's real capture size (1568 px), so its token cost is realistic but the content isn't.
- One topic (opportunity cost) for most rows, plus one real 14-minute TED talk for the video and long-text summaries. Three runs per row, so treat averages as ±1 second.
- Answers vary run to run (Claude decides whether to search the web, how long to write). Web-search rows are the most variable.
- "Cost" is what the Claude tool reports at API list prices. On a subscription it counts against your usage limits instead.
- Times start when you send; the chat's Claude process has been open 4 seconds first, like a popup you read before clicking.
  Clicking instantly (no head start) gave the same times, so the tool's startup isn't a delay you feel.

Extra measurements:

Clicking instantly, with no head start (Sonnet, Simpler chip):

| Simpler (chip) | first question | 3 | 1.4s | 4.1s | 2 | 6.8k | 141 | $0.0137 | no |
| Simpler (chip) | typed follow-up | 3 | 0.7s | 3.5s | 2 | 7.0k | 161 | $0.0037 | no |
| Simpler (chip) | Go deeper | 3 | 0.9s | 5.9s | 2 | 7.2k | 405 | $0.0063 | no |

Work Margin does on your Mac after the answer arrives (Sonnet, 3 runs): rendering the voice clips takes under a second:

| Category | Seconds |
|---|--:|
| Pronounce a sentence | 0.31s |
| Pronounce a word | 0.62s |

---

## Haiku: 3 run(s) per row

Times are seconds after you send (the chat's process has already been running 4s, as when you open a popup and then click). "First text" is when the first words appear. Tokens: new = not cached, cached = the fixed instructions re-read cheaply, out = the answer. Cost is what the same call would cost at API list prices (on your subscription it counts against usage limits instead).

| Category | Step | n | First text | Done | Input new | Input cached | Output | Cost | Used web |
|---|---|--:|--:|--:|--:|--:|--:|--:|:-:|
| Simpler (chip) | first question | 3 | 4.1s | 6.3s | 10 | 6.1k | 350 | $0.0141 | no |
| Simpler (chip) | typed follow-up | 3 | 4.4s | 9.8s | 10 | 6.5k | 297 | $0.0029 | no |
| Simpler (chip) | Go deeper | 3 | 3.5s | 8.3s | 10 | 6.9k | 470 | $0.0037 | no |
| Example? (chip) | first question | 3 | 3.9s | 6.8s | 10 | 6.1k | 369 | $0.0142 | no |
| Define terms (chip) | first question | 3 | 3.8s | 5.9s | 10 | 6.2k | 396 | $0.0143 | no |
| Typed question | first question | 3 | 3.0s | 4.7s | 10 | 6.1k | 293 | $0.0138 | no |
| No screenshot, web search off (leanest) | first question | 3 | 4.2s | 5.6s | 2.6k | 0 | 357 | $0.0043 | no |
| Blank chat (Option+Shift+Tab) | first question | 3 | 3.1s | 5.4s | 10 | 6.1k | 288 | $0.0136 | no |
| Snip (Tab+\) | first question | 3 | 4.3s | 6.7s | 10 | 6.3k | 359 | $0.0144 | no |
| Pronounce a word | answer | 3 | 17.6s | 19.6s | 10 | 6.1k | 1.7k | $0.0205 | no |
| Pronounce a sentence | answer | 3 | 41.8s | 44.7s | 10 | 6.1k | 5.2k | $0.0383 | no |
| Visualize: supply and demand | answer | 3 | 75.0s | 80.0s | 23 | 17.7k | 852 | $0.0459 | 3/3 |
| Visualize: quadratic | answer | 3 | 25.2s | 28.9s | 31 | 26.7k | 1.2k | $0.0714 | 3/3 |
| Summarize: overall meaning (short passage) | answer | 3 | 3.5s | 6.0s | 10 | 6.2k | 386 | $0.0143 | no |
| Summarize: keywords (short passage) | answer | 3 | 5.1s | 7.0s | 10 | 6.2k | 569 | $0.0152 | no |
| Summarize: meaning (3,000 characters) | answer | 3 | 5.4s | 8.0s | 10 | 6.9k | 588 | $0.0167 | no |
| Summarize: keywords (15,000 characters) | answer | 3 | 9.4s | 12.6s | 10 | 9.2k | 1.1k | $0.0237 | no |
| Fact that needs checking | answer | 3 | 13.3s | 15.9s | 18 | 13.2k | 562 | $0.0402 | 3/3 |
| YouTube summary (14:04 video) | answer | 3 | 10.0s | 18.5s | 10 | 8.0k | 1.8k | $0.0249 | no |

### Average first answer by category

| Category | n | Done | Input (all) | Output | Cost |
|---|--:|--:|--:|--:|--:|
| Graph | 6 | 54.4s | 22.2k | 1.0k | $0.0587 |
| Pronounce | 6 | 32.1s | 6.1k | 3.4k | $0.0294 |
| Quick question | 18 | 5.8s | 5.5k | 342 | $0.0124 |
| Snip | 3 | 6.7s | 6.3k | 359 | $0.0144 |
| Summarize | 12 | 8.4s | 7.1k | 652 | $0.0175 |
| Video | 3 | 18.5s | 8.0k | 1.8k | $0.0249 |
| Web search | 3 | 15.9s | 13.2k | 562 | $0.0402 |

## Sonnet: 3 run(s) per row

Times are seconds after you send (the chat's process has already been running 4s, as when you open a popup and then click). "First text" is when the first words appear. Tokens: new = not cached, cached = the fixed instructions re-read cheaply, out = the answer. Cost is what the same call would cost at API list prices (on your subscription it counts against usage limits instead).

| Category | Step | n | First text | Done | Input new | Input cached | Output | Cost | Used web |
|---|---|--:|--:|--:|--:|--:|--:|--:|:-:|
| Simpler (chip) | first question | 3 | 1.3s | 4.3s | 2 | 6.8k | 137 | $0.0137 | no |
| Simpler (chip) | typed follow-up | 3 | 1.3s | 4.0s | 2 | 6.9k | 142 | $0.0035 | no |
| Simpler (chip) | Go deeper | 3 | 1.0s | 5.8s | 2 | 7.1k | 406 | $0.0062 | no |
| Example? (chip) | first question | 3 | 1.0s | 4.0s | 2 | 6.8k | 178 | $0.0141 | no |
| Define terms (chip) | first question | 3 | 1.2s | 4.2s | 2 | 6.8k | 219 | $0.0146 | no |
| Typed question | first question | 3 | 1.9s | 4.1s | 2 | 6.8k | 145 | $0.0138 | no |
| No screenshot, web search off (leanest) | first question | 3 | 1.3s | 4.2s | 2 | 3.3k | 125 | $0.0051 | no |
| Blank chat (Option+Shift+Tab) | first question | 3 | 1.2s | 3.8s | 2 | 6.7k | 154 | $0.0135 | no |
| Snip (Tab+\) | first question | 3 | 1.5s | 3.9s | 2 | 6.9k | 204 | $0.0149 | no |
| Pronounce a word | answer | 3 | 2.6s | 5.3s | 2 | 6.7k | 337 | $0.0153 | no |
| Pronounce a sentence | answer | 3 | 2.1s | 7.0s | 2 | 6.7k | 492 | $0.0169 | no |
| Visualize: supply and demand | answer | 3 | 1.3s | 5.0s | 2 | 6.7k | 439 | $0.0164 | no |
| Visualize: quadratic | answer | 3 | 1.2s | 4.3s | 2 | 6.7k | 324 | $0.0152 | no |
| Summarize: overall meaning (short passage) | answer | 3 | 1.1s | 3.8s | 2 | 6.8k | 169 | $0.0142 | no |
| Summarize: keywords (short passage) | answer | 3 | 1.3s | 4.6s | 2 | 6.8k | 239 | $0.0149 | no |
| Summarize: meaning (3,000 characters) | answer | 3 | 1.3s | 4.4s | 2 | 7.6k | 237 | $0.0182 | no |
| Summarize: keywords (15,000 characters) | answer | 3 | 2.7s | 6.5s | 2 | 10.7k | 350 | $0.0315 | no |
| Fact that needs checking | answer | 3 | 6.1s | 8.3s | 3 | 9.4k | 430 | $0.0263 | 1/3 |
| YouTube summary (14:04 video) | answer | 3 | 1.3s | 9.9s | 2 | 9.1k | 1.0k | $0.0317 | no |

### Average first answer by category

| Category | n | Done | Input (all) | Output | Cost |
|---|--:|--:|--:|--:|--:|
| Graph | 6 | 4.7s | 6.7k | 382 | $0.0158 |
| Pronounce | 6 | 6.2s | 6.7k | 415 | $0.0161 |
| Quick question | 18 | 4.1s | 6.2k | 160 | $0.0125 |
| Snip | 3 | 3.9s | 6.9k | 204 | $0.0149 |
| Summarize | 12 | 4.8s | 8.0k | 249 | $0.0197 |
| Video | 3 | 9.9s | 9.1k | 1.0k | $0.0317 |
| Web search | 3 | 8.3s | 9.4k | 430 | $0.0263 |

YouTube transcript download: 1.3s.
