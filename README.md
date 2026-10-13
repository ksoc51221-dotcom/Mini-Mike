# Margin

A macOS menu-bar helper for quick side-questions about text you're reading, usually a part of a Claude explanation that didn't click. It can search the web and see your screen to get the answer right, and an optional Local mode answers quick questions on your Mac to save Claude tokens. You can run up to 4 questions at once.

## What Margin can do, at a glance

Five main things, and the smaller features that belong to each:

1. **Answer questions about whatever you're reading.** Highlight text anywhere and ask (spark button, or ⌥⇧Tab for a blank chat); snip anything you can't highlight (Tab + \\); ask about a whole page or PDF. Claude can search the web and see your screen; up to 4 chats run at once and rest in a sidebar.
2. **Explain in more than words.** Pronunciation voice messages, drawn graphs, summaries (overall meaning, keywords), video summaries (YouTube, Listen Along, files; just type or say “summarize this video” in a chat), and **Quiz me**.
3. **Remember and organize.** Every chat is saved and **automatically titled and filed into a sector** (Math, Language, Physics…) **when you close them**, unless you named them yourself; **⌘⇧L** opens the history; **Keep it** saves the good explanations to a notebook, mirrored as Markdown files.
4. **Listen to you.** Hold **⌘⇧V**, say it, let go: Margin starts recording the instant you press. It can answer a question, **add an event to your calendar** ("add dinner to my calendar tomorrow 7 to 8"), or hand a job to an agent.
5. **Do jobs for you in the background: agents** (⌘⇧A). Each agent is a pixel cat on a bar at the top of your screen: **Tidy** (clean up Desktop/Downloads), **Find** files, **Study** notes and flashcards from a textbook, **Batch** file conversions, and a **custom** agent for anything else you can say about your files (“scatter these screenshots around the desktop”, “rename my PDFs Paper 1, Paper 2…”). They show you a plan, you press **Allow** or **Deny**, and everything can be undone. A big job tells you its token cost first.

And it spends as few Claude tokens as it can: it only sends what a question needs, and an optional Local mode answers simple questions on your Mac.

---

1. Highlight text in any app (drag, double-click, or shift-click).
2. A small **spark** (Claude's starburst on a cream disc) pops in next to your cursor. Click it.
3. Ask what's confusing, tap a quick chip (**Simpler**, **Example?**, **Define terms**), or just press **Return** for a simpler explanation.
4. While it researches, a status line shows what it's doing ("Searching “…”", "Reading swift.org"). Click **Minimize** (or click anywhere else) to put the chat away in the sidebar; it keeps working there.
5. Ask follow-ups or click **Go deeper** if you need more.

## Ask without highlighting: **Option+Shift+Tab**

Press **Option+Shift+Tab** anywhere for a chat right at your mouse (**New Chat** in the menu bar does the same).
- If you've highlighted text, it comes along. Otherwise you get a blank "Ask anything" chat, and Claude sees your screen as usual.
- Pressing it again while you're typing in that chat puts it away in the sidebar (an empty chat just goes away). If a chat is open but you've clicked elsewhere, the shortcut gives it the keyboard back.
- It works even while Margin is paused.

Every chat pops up with a soft light-orange glow (it blooms, then settles) and follows the chat as it moves, grows, and fades.

## Can't highlight it? Snip it: hold **Tab**, press **\\**

For scanned PDFs, images, diagrams, or any app that won't let you select text, hold **Tab** and press **\\**. You get the standard macOS crosshair, the same one as ⌘⇧4:
- Drag a box around what you're asking about.
- Or press **Space** to pick a whole window, or **Esc** to cancel.

An agent opens right there with your snip as its "highlight". It can also see the full screenshot, if screen context is on. The same thing is in the menu as **Snip & Ask…**.

The Tab key itself still works normally: Margin only swallows the **\\** while Tab is held, so nothing gets typed into your document. It uses the US-layout backslash key.

## Make it bigger

The **⤢** button in the chat header makes the popup 50% bigger: 380 → 570pt wide, and the answer area 360 → 540pt tall. Click **⤡** to go back. Margin remembers your choice for the next popup.

## Hear it: pronunciation voice messages

Highlight or snip a word or a whole sentence (Russian, French, anything), then tap **🔊 Pronounce** or ask "how do I say this?". Claude answers with a **voice message** like an Instagram voice note. For a sentence you get one clip of the whole thing at natural speed, then sometimes extra clips for the 1–3 trickiest words.

- **The bubble:** a play/pause button, a waveform that fills as it plays (tap it to jump to any point), the length, and a **🐢** button for a slow version.
- **Under the bubble:** the word with its stress marked and its IPA, e.g. **замо́к** /zɐˈmok/.
- **Auto-play:** the first clip plays once, automatically, when the answer arrives (only while the chat is open).
- **Keeping a clip:** drag the bubble into Finder or Notes to save it as an **.m4a**, or right-click → **Save Audio As…**.

**How it works:**
- Claude decides how the word should sound and writes it as IPA. That's where the stress lives, which matters a lot in Russian: за́мок (castle) and замо́к (lock) are spelled the same.
- The Mac's built-in voice for that language then speaks Claude's IPA, offline.
- Claude can't produce audio itself, so it picks the correct pronunciation and macOS does the speaking.

**Better voice:** the Mac ships with a basic "compact" Russian voice (Milena). For a more natural sound, open **System Settings → Accessibility → Spoken Content → System Voice → Manage Voices…** and download **Milena (Enhanced)** or another Russian voice. Margin automatically uses the best one installed. One caveat: I've only tested that IPA stress works with the built-in voice, so if an enhanced voice gets stress wrong, tell me.

## Summarize

Highlight a passage and tap **Summarize**, then choose:
- **Overall meaning:** the main point in a sentence or two, plus up to three short points that support it.
- **Keywords & concepts:** the 4–8 most important terms or ideas, most important first, each explained in one line.

Summaries take up to about 20,000 characters of highlighted text (other questions take about 4,000), so whole sections work. In an Option+Shift+Tab chat with nothing highlighted, Summarize works on what's on your screen.

## See it: graphs and visual models

Tap **📈 Visualize**, or ask for a graph, a diagram or "show me", and Claude draws one right in the chat. It also draws on its own when a picture would explain faster.

- **Exact curves:** Claude writes the formulas (like `a*(x-h)^2 + k` or `8 - 0.7*x`), and Margin computes and draws them. Parabolas, intersections, tangent lines, equilibrium points and shaded areas come out mathematically right, not hand-drawn.
- **Sliders:** many graphs come with sliders for "what happens if…". Drag one to shift demand, change a parabola's *a*, *h* or *k*, or move a tangent point, and the graph updates live.
- **Hover** over a graph with numbers to read the curves' values at your mouse.
- **What it can draw:**
  - math: functions, roots, vertex, asymptotes, π ticks for trig;
  - calculus: tangent lines, areas under curves;
  - economics: supply and demand, shifts, P*/Q*, consumer and producer surplus;
  - statistics: bell curves with shaded probability;
  - geometry and vectors: the unit circle, triangles, arrows;
  - diagrams: boxes and arrows for processes and cycles, like the circular flow of income.
- **Keep it:** drag the graph into Notes or Finder as a PNG, or right-click for **Copy Image** and **Save Image As…**. The picture includes your slider settings.

How it works: Claude puts a small JSON description inside a `<graph>` tag. Margin reads it with its own math parser (nothing is run as code) and draws it natively. If part of it doesn't make sense, that part is skipped and the rest still draws.

## Summarize a video

**Just ask.** In any chat, or in the agent box, or by voice (⌘⇧V), type or say **“summarize this video”** (also “what's this video about?”, “tl;dr of this video”, “summarize the lecture”, or paste a YouTube link). Margin understands that on your Mac with no Claude call and opens the video summary for the YouTube video in your front browser tab; “listen along” or “summarize what's playing” listens to whatever is playing instead. It's the same summarizer as the menu's, three ways in:

- **YouTube tab:** with a YouTube video open in Safari, Chrome, Arc, Brave, Edge, Vivaldi, or Opera, choose **YouTube Video in Current Tab**. Margin reads the video's captions straight from YouTube, so you don't have to play it. The first time, macOS asks whether Margin may read your browser's tab address. If you highlight text in a browser, or highlight a YouTube link anywhere, a **▶ Summarize video** chip also shows up in the popup.
- **Listen along:** for anything else that's playing (Instagram, a course site, a Zoom recording), choose **Listen Along…**. Margin transcribes your Mac's sound on-device while it plays. Press **Stop & summarize** when you've heard enough. You can put it away in the sidebar while it listens. It stops by itself after 3 hours.
- **A file:** choose **Video or Audio File…** and pick a video or audio file. It's transcribed on-device, faster than real time.

The summary is tight (about 450 words, not every point) and always has the same shape:
- 📌 **Executive Summary & Overview**: the core premise in one sentence, who it's for and what they take away, and the speaker and format.
- 🔑 **Key Takeaways & Core Concepts**: three bullets (the biggest insight, the main framework or argument, the key warning or conclusion).
- ⏱️ **Topic-by-Topic Breakdown**: each main section with its timestamp (for YouTube, clicking it opens the video at that moment) and its core argument and key example.
- 🛠️ **Actionable Steps & Implementation**: numbered steps, only for tutorials and how-to videos (left out otherwise).
- 💡 **Important Quotes, Tools & References**: a quote, tools or books mentioned, and people or studies cited (empty lines left out).

Then you can ask follow-ups or **Go deeper**, like any other chat.

**With Local Mode on, an English video is summarized on your Mac with no Claude call.** The model on your Mac has a small memory, so it reads a long transcript in parts (“Reading part 2 of 3 on your Mac…”), boils each down to timestamped notes, and writes the summary from the notes. That takes about 2 minutes for a 15-minute talk (longer for a long lecture) and costs no Claude tokens, where Claude would read the whole transcript (roughly 7k tokens for a 15-minute talk, 20k for an hour). A small model is less careful than Claude: it can blur a detail or miss a point, so for a video with dense data or analysis press **⌃⇧L** to have Claude redo it. Timestamps are turned into links here, from the time itself, so they always open the right moment. Questions after the summary send the model only the few transcript passages they're about. Videos in other languages always go to Claude.

**Videos that aren't in English** make Margin ask how you want the summary:
- **English + key Russian phrases:** English summary, plus useful phrases from the video as voice clips.
- **English only.**
- **Russian (practice):** the summary in simple Russian, with stress marks and short English glosses for the harder words.

**First use of Listen Along or files:** Apple's speech model for that language downloads once (a progress bar shows). English uses Apple's long-form transcriber; Russian uses Apple's dictation model, which is on-device too. Listening needs the same Screen Recording permission as screenshots, because that's how macOS lets apps hear system audio.

## The chat sidebar

Every chat rests in a **black sidebar** at the top-right of your laptop screen, like the chat list in Claude but with a circle for each chat. It has room for **4 chats** at once; beyond that you'll see a note asking you to delete one.

- **Each row** has a circle, the question, and what the chat is doing. Click a row to open that chat; click the open one again to put it back.
- **Light purple (working):** the ring pulses, a point of light orbits it, the spark in the middle turns slowly, and a soft glow breathes and radiates outward in slow ripples. The row says what it's doing ("Searching “…”").
- **Dark green (done):** one burst of light outward, then a steady emerald glow with a ✓. The row says "Done. Click to read".
- **Red glow:** something went wrong. Click the row to see what.
- **Fold it:** the button at the top right of the sidebar (or **Fold Chat Sidebar** in the menu-bar menu) shrinks it to a slim strip with one colored dot per chat. Click the strip to unfold. Margin remembers which you chose.

**Moving a chat:** drag the top edge of the chat window (the little grip, or anywhere along the header away from its buttons) and drop it wherever you like. It stays there: reopening it from the sidebar brings it back to that spot, and it no longer fades away by itself.

**Putting away and deleting:**
- Clicking anywhere outside the chat, pressing **Esc**, pressing Option+Shift+Tab again, or the header's sidebar button all **put the chat away in the sidebar**. They never delete it, even when it has finished.
- A chat only goes away when you click **×** on the chat itself or **×** on its sidebar row (it shows when you hover the row). That also stops the agent.
- One exception: a completely empty chat (opened with Option+Shift+Tab, nothing typed, nothing highlighted) has nothing to come back to, so clicking away just removes it.
- A chat you haven't moved fades after about 20s idle and goes back to the sidebar (hovering keeps it open).

## History, sectors and the notebook

Margin now keeps your chats on this Mac (turn it off with **Save chat history** in the History window's ⋯ menu), so you can find an explanation again.

- **Auto-named and filed.** Claude ends its first answer in a chat with a hidden line that names the chat (3–6 words) and files it under a **sector**: Math, Physics, Chemistry, Biology, Computer Science, Economics, Language, History, Writing, Health, Business, or a new one it makes up when none fits. It costs about 30 extra words and **no extra call**. If Claude doesn't, a quick keyword guess on your Mac files it. The sidebar row shows the sector ("Math · Done. Click to read").
- **Named when you close it.** When you close a chat that went on for more than one exchange, one small extra call (Haiku, about 600 tokens) reads what was actually said and gives it a better name and sector. **If you renamed a chat yourself, or moved it to a sector, Margin never changes that** (a lock icon in the History window shows it, and you can click it to let Margin name the chat again). Turn it off with **Name chats when I close them** in the History window's ⋯ menu.
- **Chat History…** (menu bar, or **⌘⇧L** anywhere; press it again to close) opens a window with every chat, filed by sector, searchable. Rename a chat, move it to another sector (or a new one), copy it as Markdown, delete it, or **Quiz me on this**.
- **Keep it.** Tap **Keep** under an answer to save it to your **Notebook…** (also searchable, filed by sector). Kept notes are also written as Markdown files, one per sector, in `Documents/Margin Notes` (switch that off in the ⋯ menu).

## Quiz me

After an answer, tap **Quiz me** for four questions on what you just read: three multiple choice and one short answer. Multiple choice is **graded on your Mac** (no extra Claude call to mark it); for the short answer you see Claude's answer and mark yourself. You get a score, **the questions you missed are saved to your notebook**, and the score is kept on the chat. You can retake it.

## Ask about the whole page or PDF

When the app in front has a file or web page open (Preview, Safari, Chrome, Word and so on), a chat offers **Ask about “name”**. Margin reads the whole thing on your Mac (PDFs, text, Word and RTF files, web pages; **scanned PDFs are read with on-device text recognition**, the first 40 pages) and cuts it into passages. For each question it finds the few passages that match and sends **only those** to Claude, with page numbers, so a 400-page textbook costs about as much as a paragraph. Claude cites pages like (p. 45). **Summarize document** and **Key terms** use excerpts spread through the document. A document chat is a lean call: no screenshot and no web.

## Talk to Margin: hold **Cmd+Shift+V**

Hold the keys, say what you want, let go. (While Margin runs, ⌘⇧V is Margin's, so apps' "Paste and Match Style" on that chord won't fire.) Your voice is turned into text by Apple's speech model **on your Mac**; it is never saved or sent. Only the text goes on:
- a calendar request becomes a card (below);
- a job for the background agents ("tidy my desktop") starts that agent and shows the agent bar;
- **hold ⌘⇧V and press A as well** (or hold ⌘⇧A and press V) to talk **to the agents**: the pill shows a cat, and whatever you say is taken as a job ("organize my downloads", "find the elasticity PDF", "summarize chapter 4 of my econ textbook"). If it isn't a job the agents can do, the new-job box opens with your words in it;
- "show my agents", "what are my agents doing?" or "check on my cats" shows the agent bar;
- anything else goes to the chat that's open as a follow-up, or opens a new chat at your mouse (with whatever is highlighted) and asks it.

There's nothing to set up. Voice is English only, and **it starts recording the instant you press**: the pill is up at once, and the words appear as you speak. Margin loads Apple's speech model when it starts, so a press never waits for it, and what you say before the recognizer has fully woken up is kept (in memory only) and handed to it, so no words are lost. The text is ready a fraction of a second after you let go. The first time ever, macOS asks for the microphone. (If Apple's English speech model isn't on the Mac, a small pill asks before downloading it.)

## Add to your calendar by typing or speaking

Say or type, in a chat: *"Hey, add “doing this and this” to my calendar at 8-9 on 8th of Jan 2027"*, or *"schedule a meeting with Anna next Tuesday 2-3pm"*, or *"block 9 to 11 tomorrow for studying"*. Margin reads it **on your Mac with no Claude call** (dates like "tomorrow", "next Friday", "8th of January", "in two weeks"; times like "8-9", "3pm", "noon", "for 2 hours") and shows a card with the title, date and times for you to check. Anything it had to guess is marked (for "8-9" with no am/pm it guesses and offers an **AM → PM** switch). Nothing is added until you press a button:
- **Add to Calendar** puts it in your Mac's Calendar. If your **Google account is added in System Settings → Internet Accounts with Calendars on**, it goes to your Google calendar (you can pick the calendar). The first time, macOS asks to let Margin use Calendars. **Undo** takes it back.
- **Open in Google Calendar** opens Google's own new-event page in your browser with everything filled in, for any Google account, with no permission needed.

## Background agents: **Cmd+Shift+A**

The agents have their own home, separate from your chats. **Minimized**, it's a small black strip on the **right edge of the screen, half-way down**, with a little cat for each agent (a dot of orange means one needs you). **Expanded**, it flies up to a black **agent bar** at the top centre of the screen. Click the strip, press ⌘⇧A, ask by voice, or use **Agents → Show Agents** to expand it; click elsewhere, press Esc or ⌘⇧A, or use the bar's ⤡ button to minimize it. Each agent is a different **pixel cat**:
- **sitting still**: waiting to start, or waiting for your OK (a small orange **?** shows it needs you);
- **running** back and forth: working (with a progress line when it knows how far along it is);
- **a loaf**: finished.

**When an agent needs your OK, the buttons are right on its cat:** it says what it wants to do ("19 changes · 2 to the Trash") with an orange **Allow** and a **Deny**. Allow carries the plan out; Deny changes nothing and the agent stays listed saying so. (Agents that need you to choose first, like which chapters to study, show **Review** instead, which opens the card.) The bar stays up while an agent is waiting for you, even if you click elsewhere, so the buttons can't slip away.

Click a cat to open its card underneath (the full plan, with **Allow** and **Deny** at the top, or what it's doing, or what it did, with Undo); click it again to put the card away. When the bar opens and an agent is waiting for you, its card opens by itself. **+** gives an agent a new job: type it, pick a suggestion, or drop files on the box. Hover a cat that isn't busy for its **×** to take it off the bar. When an agent needs your OK or finishes, the bar comes down by itself with that card open. Minimized or not, the agents keep working. (While Margin runs, ⌘⇧A is Margin's, not the app in front.)

- **Tidy** (“tidy my desktop”, “clean up downloads”): sorts loose files by kind and month (Screenshots/2026-10, PDFs, Images, Documents, Installers…), moves old installers (30+ days) and identical duplicate copies to the Trash, and clears empty folders. Screenshots are read with on-device text recognition and named from what's in them (“2026-10-09 Supply and demand graph”); an optional switch lets Claude write better names from that text (never the images), and **shows its token cost first** (off by default). Your own folders, hidden files, shortcuts, apps and anything changed in the last 10 minutes are left alone.
- **Find** (“where's the PDF with the elasticity table?”): Spotlight searches names and the text inside your files, with no Claude call. Show / Open buttons on each result.
- **Study** (“summarize chapter 4 of my econ textbook”, or drop a PDF): reads the file, offers its chapters (from the PDF's contents), and for the ones you pick writes a **summary, key terms, practice questions and/or flashcards** (a tab-separated file for Anki) as Markdown in `Documents/Margin Notes/Study/…`, and adds them to your notebook. It shows about how many Claude tokens it will use before it starts.
- **Batch**: convert HEIC photos to JPG, merge PDFs, read the text out of images or scans into .txt files. These make **new files** and never change the originals.
- **Anything else about your files**, said on the spot (“take all the screenshots out of the Screenshots folder and scatter them around the desktop”, “rename my PDFs Paper 1, Paper 2”, “put everything older than a month in an Archive folder”, “trash the DMGs in Downloads”). Nothing is hard-coded: Claude is shown the **names, sizes and ages** of what's in the folders (never what's inside a file) and replies with a plan made of a few safe steps: **move, copy, rename, trash, make a folder, place icons on the Desktop, write a small text file**. Margin checks every step against its safety rules, drops anything it wouldn't allow (saying why), and shows you the plan to Allow or Deny. “These screenshots” means whatever is selected in Finder. Scattering moves icons with Finder (macOS asks once to let Margin control Finder); Sort By is switched to None so they stay where they land, and **Undo puts the icons and Sort By back**. **Token warning:** a small job (about 2,000 to 3,000 tokens, under a few dozen files) just runs; a job that would read more than about 200 files stops first and says “This is a bigger job, about 7k tokens. Go ahead?” with **Go ahead** and **Cancel** (also on the cat), and one that's far too big asks for something narrower.

**How it stays safe.** Claude never touches your files and has no shell. An agent only builds a *plan*; you see it, switch off any part, and press **Allow**. Margin itself carries it out, and only:
- in your Desktop, Downloads and Documents folders;
- never on hidden files, shortcuts, or anything inside an app or package;
- never overwriting (a taken name becomes “name 2”);
- never deleting for good: “remove” means the Trash;
- with every change written to a ledger, so **Undo** puts the whole task back.
Up to three tasks run at once; the **Stop** button works at any point.

## Use fewer Claude tokens

Four things cut what Margin sends to Claude. All of them come down to not sending what a question doesn't need.

**Lean calls (always on).** Pronounce, Visualize and Summarize on highlighted text never use your screen or the web, so Margin sends them to Claude without the screenshot and without the web tools. In measurements that's about half the tokens of an ordinary question (about 3.5k instead of 6.9k). The chat's footnote says "text only · web search off" when it did this. If you then ask a follow-up that needs the web or the screen, the chat moves to a full Claude session by itself, carrying the conversation along.

**Smart screen context (default).** If you highlighted text and your question isn't about the screen or about facts that change (*latest*, *check*, *this button*…), Margin sends Claude just the highlight and its surrounding text: no screenshot and no web tools. The screenshot is still taken and kept, so a follow-up like "what's on my screen?" moves the chat to a full session that includes it. Nothing highlighted, snips, and videos still get the screenshot. Pick **Whole Screen** or **Just the App Window** under Screen Context to always send it.

**Only the instructions a question can use.** Claude's standing instructions used to include the long rules for saying words aloud and for drawing graphs in every chat. Now they go in only when the question can use them (Pronounce, Visualize, graph-ish or foreign-language words, or math/physics/economics/language text), and a later question that needs one brings it along. `Margin --tokenbench` measures it on real calls: a plain question's instructions went from 2,568 to 1,008 input tokens (60% less). Quizzes, history and calendar cards cost nothing extra: the title and sector for the History come from a single hidden line in the answer, and "add to my calendar" is understood on your Mac without calling Claude. Document chats send only the matching passages, never the whole file.

**Background tasks.** Tidy, Find and Batch use no Claude at all; only the optional screenshot naming does (about 1.5k tokens for 3 screenshots, with an estimate shown before you approve) and Study (an estimate is shown first). **The common file jobs cost nothing:** “scatter my screenshots”, “arrange these in a grid/row/column”, “trash the old installers in Downloads”, “put my PDFs in a Papers folder”, “move my screenshots to a folder called School” are planned **on your Mac by rules** (`LocalJobs.swift`), and the plan says “Planned on your Mac: no Claude tokens used.” Anything with a twist (rename, size filters, “and then…”) goes to Claude: one Haiku call that reads file *names* (sizes and ages only when the request is about age or size), about 1,500 to 2,500 tokens, shown on the plan; a job that would cost more than about 4,000 asks before spending anything.

**Chat naming** on close is done by **Ollama when Local Mode is on** (0 Claude tokens), falling back to one small Haiku call (about 600 tokens) if Ollama can't.

**Graph templates (Local Mode on).** Visualize on a highlight that clearly fits one of seven ready-made graphs (supply and demand with demand and supply shift sliders, parabola, straight line, sine wave, tangent line/derivative, exponential growth/decay, bell curve) is drawn on your Mac with no Claude call; the answer says “Answered on your Mac · graph template”, and **Ask Claude** under it asks for a custom one. If it isn't a clear fit (or two fit equally), or you ask a follow-up, Claude takes over.

**Measured floor.** A `claude -p` call with nothing in it costs about 730 input tokens (about 610 on Haiku); web tools add about 1.4k, and the default tool set about 23k (Margin always turns it off). No further `claude` flag lowers this (`--disable-slash-commands` and `--exclude-dynamic-system-prompt-sections` change nothing), so the remaining savings are in not calling Claude at all.

**Local mode (off until you turn it on).** Install [Ollama](https://ollama.com) and the model (`ollama pull qwen3:8b`), then switch on **Local Mode (Ollama)** in the menu. Quick questions (Simpler, Example?, Define terms, and typed questions), **summaries of highlighted text of any length Margin accepts (up to 20,000 characters)**, and English **video summaries** are then answered by the model on your Mac:
- Nothing is sent to Claude for those. The answer is labelled "Answered on your Mac · qwen3:8b", and **Ask Claude** under it asks Claude the same thing instead (it can search the web and see your screen).
- Always Claude: pronunciation, graphs, anything that needs the web or your screen (*check*, *verify*, *latest*, *price*, *this button*, …), translation, snips, blank chats, summaries of more than 20,000 characters, videos in other languages, and any text that's mostly in a non-Latin alphabet (the small model gets Russian stress wrong).
- A local chat stays local for follow-ups, but one that needs Claude (say, "is that the latest?") moves to Claude by itself.
- If Ollama isn't running, or the model isn't installed, the question goes to Claude and the footnote says why.
- It takes about 6 GB of memory while the model is loaded, and the model unloads after 5 idle minutes. Margin loads it while you're typing your question.
- To use another Ollama model: `defaults write com.kien.margin localModel <name>`.
- **⌃⇧L moves just the open chat between Claude and your Mac.** Say a summary turns out to have complex data that needs real analysis: press **Control+Shift+L** and Claude answers that question again, in that chat only. Press it again to hand the chat back to your Mac. It never changes the Local Mode switch, any other chat, or chats you start later (they still follow the default). A note over the chat says what happened. It won't force a chat onto your Mac when it can't run there (a snip, a blank chat, a question about the web or your screen, a non-English video, or Ollama not running). The footnote of a Mac-answered chat reminds you: “⌃⇧L for Claude”. (While Margin runs, ⌃⇧L is Margin's, not the app in front.)

**Token Savings…** in the menu shows what Claude and your Mac each answered and an estimate of the Claude tokens saved. The numbers come from a small log (`~/Library/Application Support/Margin/usage.jsonl`) that holds counts and labels only, never your text. [LOCAL-MODEL-REPORT.md](LOCAL-MODEL-REPORT.md) has the measurements behind the estimates.

## Build & run

No Xcode needed, only Command Line Tools.

```bash
./build.sh --install
```

This builds, copies the app to `~/Applications/Margin.app`, and launches it.

Margin needs two permissions, in **System Settings → Privacy & Security**:
- **Accessibility:** reads the highlighted text, and presses ⌘C as a fallback.
- **Screen Recording:** takes one screenshot when you click **?**, and powers Tab+\\ snips. macOS may ask you to quit and reopen Margin after you grant it.

**Keep permissions across updates (one-time):** by default each build is signed "ad hoc", so macOS treats every update as a new app and forgets its permissions. To fix that:

```bash
./scripts/setup-signing.sh
```

This creates a private "Margin Local Signing" certificate in its own keychain file (`~/Library/Application Support/Margin Signing/`), separate from your login keychain. It then prints one `security add-trusted-cert` command for you to run. That command trusts the certificate for code signing only, and macOS asks for your password.

After that, `build.sh` signs every build with this certificate. Grant Margin's permissions one last time and they'll stick through updates.

## What it sends, and when

Nothing leaves your Mac until you click **?** and ask. Then Claude gets:
- the highlighted text,
- about a paragraph of surrounding text,
- the app's name,
- **one screenshot** taken the moment you clicked **?**,
- your question.

The screenshot shows either the whole screen or just that app's window, per the menu setting. Margin's own windows are never included. It's sent only with your first question in that chat and isn't stored.

In a lean chat (Pronounce, Visualize, Summarize, Quiz me, or any question about highlighted text in Smart mode) there is no screenshot. In Local mode, a quick question is answered on your Mac and none of this is sent anywhere.

For a video summary, Claude gets the transcript, the title, channel, and length, and the link, but no screenshot. Margin asks YouTube for the captions directly. Listen Along and file transcription happen on your Mac, and only the finished text goes to Claude.

Chat history, the notebook and quiz results are saved only on your Mac (`~/Library/Application Support/Margin/Library`, notes also as Markdown in `Documents/Margin Notes`); turn history off in the menu. Voice clips are transcribed on your Mac; only the words go to Claude (or to the calendar parser, which doesn't call Claude). Calendar events go to your Mac's Calendar, or to a Google Calendar link you open yourself. Background tasks touch only Desktop, Downloads and Documents, never overwrite, and move to the Trash rather than delete.

Each agent that needs Claude runs its own `claude -p` process (the Claude Code CLI) on your normal Claude subscription, started when you ask the first question. Its only tools are **WebSearch** and **WebFetch** (a lean chat has none): it can't read your files or run commands. It loads no settings files, MCP servers, or saved session, and it's stopped when the chat closes.

## Menu bar

- Pause/Resume
- Model (Sonnet by default)
- **Web Search** on/off
- **Local Mode (Ollama)** on/off, with a line showing whether Ollama and the model are ready
- **Agents** (Show Agents ⌘⇧A, New Job…, Tidy Desktop, Tidy Downloads)
- **Chat History…** ⌘⇧L
- **⌃⇧L** (a shortcut, not a menu item): move the open chat between Claude and your Mac
- **Voice**: a reminder of the keys (nothing to set up)
- **Screen Context** (Smart, Whole Screen, Just the App Window, or Off)
- **Summarize Video** (YouTube Video in Current Tab, Listen Along…, Video or Audio File…)
- Launch at Login
- Token Savings…
- How to Use
- Quit

The menu also shows how many agents are running and links to any permission that's missing. Settings apply to the next agent you open.

## Tests

```bash
swift build -c release
.build/release/Margin --unittest
.build/release/Margin --selftest
.build/release/Margin --capturetest
```

- `--unittest` checks context trimming, markdown, prompts, tool status labels, the Local mode router (who answers what), Ollama reply parsing, and clipboard save/restore. It puts your real clipboard back afterwards.
- `--localtest` is a live run against Ollama (it needs the model installed; no Claude calls): a local answer streams in, a follow-up remembers the chat, and the chat window routes, labels and logs it. `--localtest claude` also makes a few small real Claude calls to check Ask Claude, a follow-up that moves to Claude, a lean call, and the fall-back when Ollama is unreachable.
- `--localdemo <dir>` saves pictures of a chat in Local mode: the opening footnote, a local answer with its label, and the Ask Claude button.
- `--saytest` is a live run. It asks Claude to pronounce «замок» in a "locked the door" sentence, checks that it returns a voice clip with IPA, and renders it. `--saytest sentence` asks for the whole sentence and checks that the IPA lines up word for word.
- `--youtubetest [id]` is a live run. It fetches a YouTube transcript (a TED talk by default), asks Claude for the summary, and checks it has timestamp links.
- `--selftest` is a live run. It attaches a generated "screenshot", forces a web search, checks that Claude read the image, then asks a follow-up.
- Results of a full live benchmark (every kind of request, real prompts, real Claude, 2026-10-09) are in [BENCHMARK.md](BENCHMARK.md). The runner that produced them is no longer in the project.
- `--summarydemo <dir>` is a live run through the real chat window. It taps Summarize, shows the two choices, runs both summaries on a passage, and saves a snapshot of each step.
- `--graphtest [dir]` is a live run. It asks Claude for three visuals (a demand shift, a quadratic's roots and vertex, a tangent line) and checks each answer has a graph that draws with nothing skipped. With a folder, it saves pictures.
- `--glowtest [dir]` opens a chat through the shortcut's code path and checks the glow follows it through pop-up, minimize, expand, resize, and close. With a folder, it saves a picture.
- `--placetest [dir]` shows the sidebar with 4 finished chats on your real screen. It checks that it fits, that each circle is in its slot with its glow centered, and that the check is centered inside. With a folder, it also saves a picture.
- `--sidebartest [dir]` runs the sidebar's rules with test chats on your real screen (no questions are asked): clicking away keeps a chat, a row reopens it, dragging the header moves it and it comes back to the same spot, only × deletes, the sidebar folds and unfolds, and it fits 4 chats and refuses a fifth. With a folder, it saves a picture.
- `--capturetest` checks Screen Recording permission and grabs one frame.
- `--libtest` is a live run: the first answer must carry a title and sector, and "Quiz me" must come back as a quiz Margin can parse. `--libdemo <dir>` saves pictures of the quiz and history window with sample chats in a temporary library.
- `--calendardemo <dir>` asks a test chat to add an event and saves a picture of the card (nothing is added; no calendar access is requested).
- `--voicecheck` prints what voice has to work with (microphone permission, which speech models are installed) without recording or downloading. `--voicetest` runs the speech-to-text and calendar chain with a synthesized voice in place of the microphone. `--voicedictation` feeds synthesized speech into the hold-to-talk recorder the way the microphone would (including words that arrive before the recognizer is ready) and checks nothing is lost and the text is ready fast. `--voicelag` times each step of starting to listen. `--micprobe` (run through `open`, so it's checked as Margin itself) turns the real microphone on for 1.5 seconds and reports only how fast it started and how loud it was: nothing is kept or recognized. `--pilldemo <dir>` pictures the listening pill.
- `--doctest` is a live run: a 40-page PDF, a question about one page, and a real Claude answer from only the matching passage.
- `--tokenbench` sends the same small question with and without the optional voice/graph instructions to Haiku (3 tiny calls) and prints the input tokens each used.
- `--agentbartest <dir>` checks the agent bar: no agents in the chat sidebar, the bar at the top centre, a different cat per agent in the right pose, the card under its cat, clicks on a cat, × and +, hide and show. Uses temporary folders and no Claude; saves pictures of the bar and the card.
- The unit tests also cover the Mac-planned jobs (what's understood, what's left to Claude, running and undoing them), the graph templates (each one draws with nothing skipped; clear fits, ties and misses), and Ollama chat naming with its fall-back. `--namingtest local` is a live run of naming through Ollama.
- `--switchtest` is a live run (real Ollama and Claude, Local Mode switched on for the test and put back): ⌃⇧L moves one chat to Claude and back while another chat, Local Mode and a new chat stay on the Mac; a 4,000-character summary is answered on the Mac; a real TED talk is summarized on the Mac in the five-section shape, read in parts, with working timestamp links and a follow-up. Test chats open in the top-left corner of the screen, never the middle.
- `--customtest` is a live run of the custom agent against a made-up Desktop in a temporary folder and a pretend Finder (your Desktop is never touched): the real Claude plans “take all the screenshots out of the Screenshots folder and scatter them around the desktop”, a rename-and-file job and an impossible one; it checks the plans are safe and valid, the files end up where they should, Undo works, and the cost is under 4,000 tokens. The AppleScript sent to Finder is compiled (not run). The unit tests cover the same with a pretend Claude: understanding the request, choosing files, refusing unsafe steps, running and undoing every kind of step, and the token warning.
- `--namingtest` is a live run: real Claude names two made-up chats as if closed (in a temporary library), and a chat you rename while Claude is thinking keeps your name. `--videochattest` checks that “summarize this video” typed into a chat opens the video summary.
- `--catsheet <png>` draws every cat in every pose (sitting, the 4 running frames, loaf) on white and on black.
- `--taskdemo <dir>` runs Tidy on a fake messy desktop in a temporary folder: scan, plan, approval with Claude naming the screenshots, result, undo. Your real folders are never touched. It needs the permission to have been granted to whatever runs it.

```bash
.build/release/Margin --demo /tmp/margin-demo
```

`--videodemo <dir>` saves snapshots of the Listen Along screen, the "how should I summarize it?" choice, and a real YouTube summary.

`--graphdemo <dir>` renders sample graphs (quadratic, supply and demand, tangent, sine, unit circle, circular flow, bell curve) in dark and light, plus a chat with a graph answer.

`--demo` drives one real agent through the whole cycle: open, ask, minimize while it's thinking, turn green, expand, close. It saves PNG snapshots of Margin's own windows at each step. It never takes keyboard focus and ignores your clicks, so you can keep working while it runs.

## How it stays smooth

- The popup measures itself invisibly first, then springs in at its real size.
- When it grows, the window glides instead of jumping.
- Answers flow in at a steady 60 fps (a typewriter buffer) instead of arriving in bursts. Half-typed markdown, like an unclosed `**` or a link whose URL is still arriving, is hidden until it's complete.
- **Minimize and expand** fly a snapshot of the chat to and from its circle on the GPU, so the real window never resizes with live content inside it.
- Sidebar rows and the **?** pop in with a spring, and the idle fade is one continuous animation.

## Files

| File | What it does |
|---|---|
| `SelectionWatcher.swift` | Global mouse monitors that decide "the user just highlighted something" |
| `SelectionReader.swift` | Accessibility-API and ⌘C reading, nearby-context lookup, clipboard snapshot |
| `ScreenCapture.swift` | One-shot screenshot via ScreenCaptureKit (screen or front window, Margin excluded) |
| `Hotkeys.swift` | The global chords, Option+Shift+Tab and Tab+\\ (one event tap on its own thread) |
| `MathExpr.swift` | The safe math parser for graph formulas (implicit multiplication, x², functions, sliders) |
| `Graph.swift` | Reads Claude's graph JSON and computes curves, intersections, areas and lines |
| `GraphView.swift` | Draws graphs (axes, ticks, labels that dodge each other), sliders, hover readout, image export |
| `Answer.swift` | Splits an answer into text, voice clips and graphs |
| `PanelGlow.swift` | The light-orange glow around a chat (a click-through window that follows it) |
| `Snipper.swift` | Runs the macOS region picker and downsizes the snip for Claude |
| `ClaudeMark.swift` | The spark mark, drawn in code: trigger button, menu bar, app icon, sidebar |
| `Speech.swift` | `<say>` tags → native voice (with Claude's IPA) → trimmed .m4a, waveform, playback |
| `VoiceMessageView.swift` | The Instagram-style voice bubble, and answers that mix text with clips |
| `Video.swift` | Video sources, YouTube captions (via YouTube's app API), reading the browser tab, transcript formatting |
| `Transcription.swift` | On-device speech-to-text (SpeechAnalyzer): system audio for Listen Along, or a file |
| `scripts/setup-signing.sh` | One-time private signing identity so permissions survive rebuilds |
| `Motion.swift` | Shared curves, spring pop-ins, and the snapshot "ghost" used for minimize and expand |
| `TriggerIcon.swift` | The floating **?** bubble, plus shared theme helpers |
| `AskPanel.swift` | One agent: draggable popup window, minimize/expand, phases, picking who answers, screenshot handoff, 20s fade |
| `AskView.swift` | SwiftUI content: quote, chips, live status, streaming answers, Minimize, Go deeper, Ask Claude |
| `AgentDock.swift` | Up to 4 agents, which one is open, the "all busy" notice |
| `AgentSidebar.swift` | The black sidebar: rows, fold/unfold, hover ×, where circles fly to |
| `AgentBubble.swift` | The row circle with the purple or green glow, and the aura around it |
| `ClaudeSession.swift` | `claude -p` process: stream-json in and out, images, tool activity, per-turn token counts. Also the `AnswerSession` protocol Claude and the local model share |
| `Router.swift` | Local mode's policy: who answers a question (the local model, a lean Claude call, or full Claude), and when a chat moves up. Pure functions, unit-tested |
| `Ollama.swift` | The Ollama client (is it running? is the model there? load it ahead of time) and `LocalSession`, which streams an answer from the model on your Mac |
| `UsageLog.swift` | The private count of what each answer used, and the Token Savings summary |
| `LocalTests.swift` | Tests and demo for Local mode (`--unittest`, `--localtest`, `--localdemo`) |
| `Prompts.swift` | System prompt and message templates. Tweak answer style here |
| `StatusMenu.swift` | Menu-bar menu |
| `Library.swift` | Saved chats and notes (JSON files on this Mac), sectors and the keyword guess, search, Markdown notebook |
| `LibraryWindow.swift` | The History & Notebook window |
| `Quiz.swift` | The quiz format, local grading, and the quiz card |
| `CalendarIntent.swift` | Reads "add … to my calendar" (dates, times, titles) on this Mac |
| `CalendarStore.swift` | Adds events through macOS Calendar (EventKit), Undo, and the Google Calendar link |
| `EventCard.swift` | The editable event card |
| `Voice.swift` | Hold-to-talk: microphone, the listening pill, and where a spoken command goes |
| `PageReader.swift` | Reads a PDF, file or web page, cuts it into passages and finds the ones that match (BM25), plus on-device OCR |
| `FileSafety.swift` | The only code that changes your files: allowed folders, no overwrite, Trash only, ledger and Undo |
| `ClaudeOneShot.swift` | One-off Claude calls for the background agents |
| `TaskModels.swift`, `TaskEngine.swift` | Plans, reports, the running-task list, and the Tidy agent |
| `Tidy.swift`, `FindAgent.swift`, `BatchAgent.swift`, `StudyAgent.swift` | The four stock background agents |
| `CustomAgent.swift` | The open-ended agent: lists names, sizes and ages, asks Claude for a plan out of safe steps, validates it, warns about the token cost, runs it and keeps the ledger |
| `FinderDesktop.swift` | Desktop icon positions through Finder (AppleScript): scatter, grid, row and column layouts, Finder's selection, and putting everything back |
| `ChatNaming.swift` | Names and files a chat when it's closed, never one you named yourself |
| `VideoIntent.swift` | Understands “summarize this video” in a chat, by voice or in the agent box, and finds the video in your browser tab |
| `VideoDigest.swift` | Local video summaries: cuts a transcript into parts, the notes prompts, timestamp links, and transcript passages for follow-ups |
| `LocalJobs.swift` | Plans the common file jobs (scatter, arrange, trash old installers, put files in a folder) on this Mac by rules: no Claude call |
| `GraphTemplates.swift` | Seven ready-made graphs and the session that hands one over with no model (Local Mode) |
| `CustomAgentTests.swift` | Tests for the open-ended agent (pretend Claude, pretend Finder) and `--customtest` |
| `AgentBar.swift` | The agent bar at the top of the screen (⌘⇧A): one cat per agent, cards under the cats, + for a new job |
| `Dictation.swift` | Hold-to-talk recording: microphone on instantly, held in memory until the recognizer is ready, English only, nothing saved |
| `PixelCat.swift` | The eight pixel cats and their poses (sitting, running, loaf), drawn from letter grids |
| `TaskBox.swift` | The new-job box, the request router, and the task card |
| `FeatureTests.swift` | Tests and demos for all of the above |
