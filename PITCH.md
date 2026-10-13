# Margin: 120-second pitch (showcase only)

**Total: 2:00.** About 240 spoken words, with room for the demos to run. The right-hand column is what's on screen while you say it.
Three big demos (textbook, YouTube, agent) and one rapid-fire close. Nothing is explained that isn't shown.

| Time | Say | Do on screen |
|---|---|---|
| **0:00–0:08** | "This is Margin: an assistant that lives in the margin of whatever you're reading. Highlight, ask, done." | Textbook PDF already open in Preview. Menu-bar spark visible. |
| **0:08–0:38**<br>**Textbook** | "Here's a dense economics chapter. I highlight a section… tap Summarize… and get the main point in two sentences plus the key terms. That section was three pages; Margin only sent Claude what I highlighted. Now Visualize: it draws the supply-and-demand shift with exact curves, not a sketch. And Quiz me: four questions on what I just read, graded on my Mac." | Highlight a section → spark → **Summarize → Overall meaning**. Then tap **📈 Visualize** (graph draws). Then **Quiz me** → answer one question so the score shows. |
| **0:38–1:03**<br>**YouTube** | "Now a lecture on YouTube. I don't open anything. I just hold Command-Shift-V and say: 'Summarize this video.'… Margin pulls the captions, and I get an executive summary, the key takeaways, and a topic-by-topic breakdown, each topic with a timestamp. Click one: the video jumps there. It's a forty-minute lecture, summarized before I'd have finished the intro." | YouTube lecture in the front Safari/Chrome tab. Hold **⌘⇧V**, say it, release. Summary appears; **click a timestamp**. (Typing "summarize this video" in any chat does the same.) |
| **1:03–1:38**<br>**Agent** | "Margin also does jobs, in the background. My desktop is a mess of screenshots. Command-Shift-V plus A, to talk to an agent: 'Take all my screenshots and scatter them around the desktop.'… A cat agent starts. It shows me a plan first: move these, scatter those. Nothing has changed yet. I press Allow… and they fly apart. Didn't want that? Undo, and every icon goes back. This one was planned on my Mac, so zero tokens (the plan says so). Anything bigger tells me its cost before it spends a thing." | Hold **⌘⇧V + A**, say the request. Cat bar drops from the top; plan card with **Allow / Deny**. Click **Allow** (icons scatter). Click **Undo** (icons return). Point at the cat slot. |
| **1:38–1:55**<br>**Rapid fire** | "And the rest just works. Say 'add dinner to my calendar tomorrow at seven': a card, one click. Command-Shift-L: every chat I've had, already named and filed by subject. Quick questions can answer on my Mac for free." | Voice → calendar card → **Add**. Press **⌘⇧L** → history window, chats filed by sector. Flash menu-bar **Token Savings**. |
| **1:55–2:00** | "Margin. Highlight it, say it, done." | Menu-bar spark on screen. Stop. |

## Spoken script, as one block (for rehearsing)

> This is Margin: an assistant that lives in the margin of whatever you're reading. Highlight, ask, done.
>
> Here's a dense economics chapter. I highlight a section, tap Summarize, and get the main point in two sentences plus the key terms. Margin only sent Claude what I highlighted. Now Visualize: it draws the supply-and-demand shift with exact curves, not a sketch. And Quiz me: four questions on what I just read, graded on my Mac.
>
> Now a lecture on YouTube. I don't open anything. I hold Command-Shift-V and say: "Summarize this video." Margin pulls the captions, and I get an executive summary, the key takeaways, and a topic-by-topic breakdown with timestamps. Click one, and the video jumps there.
>
> Margin also does jobs in the background. My desktop is a mess of screenshots. Command-Shift-V plus A, to talk to an agent: "Take all my screenshots and scatter them around the desktop." A cat agent starts, and shows me a plan first. Nothing has changed yet. I press Allow, and they fly apart. Didn't want that? Undo, and every icon goes back. This one was planned on my Mac, so it cost zero tokens; a bigger job tells me its cost before it spends anything.
>
> And the rest just works. "Add dinner to my calendar tomorrow at seven": a card, one click. Command-Shift-L: every chat I've had, already named and filed by subject. Quick questions can even be answered on my Mac, for free.
>
> Margin. Highlight it, say it, done.

(About 240 words, roughly 95 seconds of talking at a natural pace, which leaves about 25 seconds of quiet for the things on screen to happen. If you run long, cut the Quiz sentence and the Local-mode line.)

## Before you go on stage

1. **Install the latest build:** `./build.sh --install`, then launch `~/Applications/Margin.app`.
2. **Grant the permissions once, in advance** (each one prompts the first time and would eat your demo): Microphone and Speech (first ⌘⇧V), Screen Recording (screenshots), **Automation → Finder** (the first time an agent scatters icons) and **Automation → your browser** (the first "summarize this video"), Calendars (first calendar card).
3. **Dry-run the exact agent request once** with a few throwaway screenshots on the Desktop, so the Finder permission is granted and you've seen the plan. Press Undo to reset.
4. **Put 6–10 screenshots on the Desktop** before you start (the scatter reads better with a handful of icons). Keep the rest of the Desktop clean so the icons are visible.
5. **Pick the video in advance:** a YouTube lecture with captions (not a music video), already open in the front tab of Safari or Chrome.
6. **Pick the textbook page in advance** (Preview, a chapter with a clear supply-and-demand section) so Visualize has something to draw.
7. **Local mode:** the closing line about answering on your Mac is true only if you've turned on **Local Mode (Ollama)** in the menu (it needs Ollama and the model installed). Otherwise cut that sentence.
8. **Local Mode and the video demo:** with Local Mode on, an English video is summarized on your Mac, which takes about 2 minutes for a 15-minute talk (longer for a lecture). That's far too slow for a 25-second slot. For the live demo either switch Local Mode off in the menu first, or open the video chat and press **⌃⇧L** so Claude does it (seconds). You can also show the Mac version in your rapid-fire close as “free, a bit slower”.
9. **Do Not Disturb on**, Dock hidden if you can, and quit anything that would pop a notification.

## If something goes wrong on stage

- **Voice doesn't catch it:** type it. "Summarize this video" typed in any chat does the same thing; the agent box (⌘⇧A, then +) takes the scatter request as text.
- **The video has no captions:** say "listen along" and play it; Margin transcribes it on-device. Or pick another video in rehearsal; most lectures have captions.
- **Scatter says Finder needs permission:** System Settings → Privacy & Security → Automation → Margin → Finder. Do this in step 3 above, not live.
- **The Visualize graph is slow:** keep talking over the "Quiz me" step and come back to it.

## Two-line versions, if you're cut down

- **60 seconds:** textbook summarize (20 s) → "summarize this video" by voice (20 s) → scatter agent with Allow and Undo (20 s).
- **30 seconds:** highlight → summary; say "summarize this video"; "scatter my screenshots" → Allow → Undo.
