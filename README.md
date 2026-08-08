# خُطاي — Khutai 🪷

**An Arabic daily planner for macOS.** You add your tasks and their deadlines; it breaks each goal into concrete steps and spreads them across the days *before* the deadline — so nothing piles up on delivery day.

Planning runs through the **ChatGPT subscription already on your Mac**. No API key, no extra subscription, no account to create.

> The app interface is entirely in Arabic (right-to-left). This README is in English so the code and setup are readable to everyone.

---

## Themes

Two color themes, switchable from the button at the top of the window. Your choice applies to the desktop widget too.

| Lotus 🪷 | Stars 🌟 |
|:---:|:---:|
| ![Lotus theme](docs/lotus.png) | ![Stars theme](docs/stars.png) |

---

## What it does

**Breaks goals into steps.** Type "submit graduation project" with a deadline, and it becomes specific steps spread across days, each with an estimated duration in minutes.

**Respects your capacity.** Never schedules more than five actual working hours per day for work tasks — the overflow moves to earlier days.

**Two separate tracks.** "Work" and "Personal", because a day isn't one block.

**Desktop widget.** Today's steps in front of you, tickable without opening the app.

**Monthly calendar.** A dot under every day that has a plan, plus a page collecting the month's achievements.

**Rotating reminders.** A verse, a line of poetry, or a thought — changes every hour.

**Cleans up after itself.** A completed task stays visible for one day, then deletes automatically — while its record remains in the monthly achievements.

---

## Before you start

You need all three:

| | |
|---|---|
| **Chip** | Apple Silicon (M1 or newer). Intel Macs will not run it. |
| **OS** | macOS 14.0 (Sonoma) or later |
| **AI** | [ChatGPT for macOS](https://openai.com/chatgpt/download) installed and signed in |

Not sure about your chip? Apple menu → **About This Mac**. It must say Apple M1, M2, M3, or M4.

---

## Install

### Step 1 — Download

Go to the [**Releases page**](../../releases), download `Khutai.zip`, and unzip it.

### Step 2 — Move it

Drag **خُطاي** into your `Applications` folder.

### Step 3 — Let macOS open it

The first time, macOS will refuse to open the app and call it "damaged". This is expected — see [why](#why-does-macos-say-the-app-is-damaged) below. To clear it:

**a.** Open Terminal — press `Cmd + Space`, type `Terminal`, press Enter.

**b.** Type this **and leave a space at the end. Do not press Enter yet:**

```bash
xattr -cr 
```

**c.** Now drag the **خُطاي** app out of your Applications folder and drop it onto the Terminal window. Its full path appears automatically.

**d.** Press Enter.

> **Why drag instead of typing the path?** The app's name is in Arabic. Typing or pasting it by hand frequently fails and produces `No such file or directory`. Dragging always gets it right.

### Step 4 — Open it

Double-click **خُطاي**. It opens normally from now on — this whole procedure is one time only.

### Optional — Verify your download

If you want to confirm the file wasn't tampered with in transit:

```bash
shasum -a 256 ~/Downloads/Khutai.zip
```

Compare the result to the checksum published on the [release page](../../releases). If they differ, **delete the file and do not open it**.

---

## Troubleshooting

**`No such file or directory`**
The app's path didn't reach the command. Redo Step 3 and make sure you *drag* the app onto the Terminal window rather than typing its name.

**Still says "damaged" after Step 3**
You probably missed the space after `xattr -cr`, so the path ran into the command. Redo Step 3 carefully.

**The app opens, but planning shows an error**
The ChatGPT app isn't installed, or you aren't signed into it. Open ChatGPT, sign in, then try planning again.

**"You've reached your usage limit"**
That's your ChatGPT plan's limit, not the app's. Wait for your usage window to reset, or use a plan with higher limits. Note that every task you add triggers a planning run.

**Nothing happens at all when I open it**
Your Mac is almost certainly Intel rather than Apple Silicon. Check Apple menu → About This Mac.

**I want to remove it completely**
Delete the app from `Applications`, then delete the folder `~/Library/Application Support/KhutayPlanner/`.

---

## Privacy

**The app makes no network connections.** There is no networking code anywhere — no `URLSession`, no URLs, no web views. Verify it yourself:

```bash
grep -rn "URLSession\|https://\|WKWebView" --include="*.swift" .
```

The AI runs by invoking the `codex` binary installed **locally** on your Mac, and that binary talks to *your* ChatGPT account. The app itself never touches a network.

**All data stays local**, in `~/Library/Application Support/KhutayPlanner/`.

No tracking, no analytics, no ads, no stored API keys.

When planning runs, `codex` is invoked in a restricted mode — `--sandbox read-only`, `--ephemeral`, inside an isolated temporary directory that is deleted afterward. The model cannot write to your files.

Instead of the ChatGPT app, a `codex` binary in any of these locations also works:

```
/opt/homebrew/bin/codex
/usr/local/bin/codex
/Applications/ChatGPT.app/Contents/Resources/codex
```

---

## Why does macOS say the app is "damaged"?

Because it is **not signed with an Apple Developer certificate and not notarized**.

That doesn't mean anything is wrong with it. It means I haven't paid Apple's annual developer program fee. macOS shows this warning for *every* unsigned app from outside the App Store, regardless of what's inside it.

**Since that asks you to take my word for it, the source is fully open here** — read it, build it yourself, or verify the checksum. That's what I can offer in place of a certificate.

> **General advice:** don't get in the habit of running `xattr -cr` on things you download. It disables a real protection. Do it only when you know and trust the source.

---

## Build from source

Requires Xcode.

```bash
git clone https://github.com/ISSQ1/Khutai.git
cd Khutai
./build.sh
```

The script builds the app, signs it locally, and places it in `build/ReleaseBuild/Release/`.

```bash
./build.sh --install   # build, then replace the copy in /Applications
./build.sh --package   # build, then produce Khutai.zip with its SHA-256
```

### Project layout

```
LotusPlanner/
    LotusPlannerApp.swift      entry point
    ContentView.swift          main interface
    PlannerStore.swift         app state and logic
    AIPlanner.swift            Codex invocation and plan parsing
LotusPlannerWidget/
    LotusPlannerWidget.swift   desktop widget
Shared/
    PlannerData.swift          models, themes, storage
```

SwiftUI and WidgetKit. No external dependencies.

---

## FAQ

**Does it use up my ChatGPT quota?**
Yes, it uses your plan's limits. Nothing is billed to me and I never see your data or usage.

**Can I use it without ChatGPT?**
It opens and works as a plain task list, but the AI planning won't run.

**Is it Arabic only?**
Yes — the interface is fully Arabic with right-to-left layout.

**Why won't it run on my Intel Mac?**
The prebuilt binary is arm64-only. You can build from source if you want to try it.

---

## Contributing

Feedback and suggestions are welcome via [Issues](../../issues).

## License

[MIT](LICENSE) — use, modify, and distribute freely, keeping the license notice.
