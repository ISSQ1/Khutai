# خُطاي, Khutai 🪷

**An Arabic daily planner for macOS.** Add your tasks with their deadlines and priorities. Khutai follows the instructions you write in each task, suggests when to start so nothing piles up on delivery day, and keeps your appointments, reminders and achievements in one calm place.

The AI runs through the **ChatGPT or Claude subscription already on your Mac**. No API key, no extra subscription, no account to create.

> The app interface is entirely in Arabic (right-to-left). This README is in English so the code and setup are readable to everyone.

---

## Themes

Two color themes, switchable from the button at the top of the window. Your choice applies to the desktop widget too.

| Lotus 🪷 | Stars 🌟 |
|:---:|:---:|
| ![Lotus theme](docs/lotus.png) | ![Stars theme](docs/stars.png) |

---

## What it does

**Your description is the instruction.** A task without a description is added exactly as written. If you list steps, only those steps are added, with no invented dates. Reminder and planning requests ("remind me a day before", "needs about three hours over two days") are applied to the task. Extra steps are suggested only when you ask, and added only after you approve them.

**Priority for every task.** High, medium or low, set when you create the task and shown on its card.

**Knows when you should start.** From the deadline, the effort you mention, priority, your daily capacity and your calendar, Khutai suggests a start day for each task and warns you early when time is getting short. It never moves your tasks on its own.

**Calendar, Reminders and notifications.**
- Your macOS Calendar appointments appear in today's plan and the monthly calendar; appointments you add from Khutai are saved to a «خُطاي» calendar.
- Main tasks can sync with a «خُطاي» list in the Reminders app, so they reach your iPhone. Completion syncs both ways, and the reminders you ask for become alerts there.
- Notifications for a morning summary, upcoming appointments, start days and deadline reminders. Tapping the morning summary opens a short morning review.

**Two separate tracks.** "Work" and "Personal", and a task can move between them at any time.

**Monthly calendar and permanent history.** Deadlines and appointments marked on a compact calendar, with the main tasks you completed listed underneath. Browse any month or year; nothing is deleted automatically.

**Desktop widget.** Title and motto fixed at the top, your tasks scrollable with arrows, plus your next appointment. Small, medium and large sizes.

**Choose your AI.** Codex (ChatGPT) or Claude, and the model you prefer, from Settings.

**Rotating reminders.** A verse, a line of poetry, or a thought, changing every hour.

---

## Before you start

| | |
|---|---|
| **Mac** | Any Mac with Apple Silicon or Intel |
| **OS** | macOS 14.0 (Sonoma) or later |
| **AI (optional)** | [ChatGPT for macOS](https://openai.com/chatgpt/download) signed in, **or** [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude` command) signed in |

Without an AI tool the app still works as a full planner; only reading task descriptions and suggesting steps need it.

---

## Install

### Step 1, Download

Go to the [**Releases page**](../../releases), download `Khutai.zip`, and unzip it.

### Step 2, Move it

Drag **خُطاي** into your `Applications` folder.

### Step 3, Let macOS open it

The first time, macOS will refuse to open the app and call it "damaged" or "cannot be verified". This is expected, see [why](#why-does-macos-say-the-app-is-damaged) below. To clear it:

**a.** Open Terminal: press `Cmd + Space`, type `Terminal`, press Enter.

**b.** Type this **and leave a space at the end. Do not press Enter yet:**

```bash
xattr -cr 
```

**c.** Now drag the **خُطاي** app out of your Applications folder and drop it onto the Terminal window. Its full path appears automatically.

**d.** Press Enter.

> **Why drag instead of typing the path?** The app's name is in Arabic. Typing or pasting it by hand frequently fails and produces `No such file or directory`. Dragging always gets it right.

### Step 4, Open it

Double-click **خُطاي**. It opens normally from now on; this procedure is one time only.

### Step 5, Allow what you want to use

The first launch asks for **Notifications**. In ⚙️ Settings inside the app you can also connect **Calendar** and **Reminders**; macOS asks for permission once for each.

### Optional, Verify your download

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

**The AI shows an error**
The chosen tool isn't installed or isn't signed in. For ChatGPT, open the ChatGPT app and sign in. For Claude, run `claude` once in Terminal and sign in. You can switch between them in ⚙️ Settings.

**"You've reached your usage limit"**
That's your ChatGPT or Claude plan's limit, not the app's. Wait for it to reset, or switch to the other provider in Settings.

**No notifications, or Calendar/Reminders don't connect**
Check System Settings → Notifications → خُطاي, and System Settings → Privacy & Security → Calendars / Reminders. Because the app isn't signed by Apple, macOS may ask for these permissions again after an update.

**The widget looks old after an update**
Remove it from the desktop and add it again.

**I want to remove it completely**
Delete the app from `Applications`, then delete the folder `~/Library/Application Support/KhutayPlanner/`. If you used them, you can also delete the «خُطاي» calendar and Reminders list.

---

## Privacy

**The app itself makes no network connections.** There is no networking code anywhere: no `URLSession`, no web URLs, no web views. Verify it yourself:

```bash
grep -rn "URLSession\|https://\|WKWebView" --include="*.swift" .
```

The AI runs by invoking a command-line tool installed **locally** on your Mac (`codex` or `claude`), and that tool talks to *your own* account. It runs in an isolated temporary folder that is deleted afterward, with no permission to change your files.

Calendar and Reminders are accessed through Apple's EventKit on your Mac, only after you allow it.

**All app data stays local**, in `~/Library/Application Support/KhutayPlanner/`. No tracking, no analytics, no ads, no stored API keys.

The tools are looked up in these locations:

```
codex:  /opt/homebrew/bin  ·  /usr/local/bin  ·  ~/.local/bin  ·  /Applications/ChatGPT.app/Contents/Resources
claude: ~/.local/bin  ·  ~/.claude/local  ·  /opt/homebrew/bin  ·  /usr/local/bin
```

---

## Why does macOS say the app is "damaged"?

Because it is **not signed with an Apple Developer ID certificate and not notarized**.

That doesn't mean anything is wrong with it. It means the app isn't enrolled in Apple's paid developer program. macOS shows this warning for *every* unsigned app from outside the App Store, regardless of what's inside it.

**Since that asks you to take my word for it, the source is fully open here.** Read it, build it yourself, or verify the checksum.

> **General advice:** don't get in the habit of running `xattr -cr` on things you download. It disables a real protection. Do it only when you know and trust the source.

---

## Build from source

Requires Xcode.

```bash
git clone https://github.com/ISSQ1/Khutai.git
cd Khutai
./build.sh
```

The script builds a universal app (Apple Silicon and Intel), signs it locally, and places it in `build/ReleaseBuild/Release/`.

```bash
./build.sh --install   # build, then replace the copy in /Applications
./build.sh --package   # build, then produce dist/Khutai.zip with its SHA-256
```

### Project layout

```
LotusPlanner/
    LotusPlannerApp.swift        entry point
    ContentView.swift            main interface
    SettingsView.swift           settings and morning review
    PlannerStore.swift           app state and logic
    AIPlanner.swift              Codex / Claude invocation and parsing
    Scheduler.swift              suggested start days and capacity
    CalendarSync.swift           Calendar and Reminders (EventKit)
    NotificationService.swift    local notifications
LotusPlannerWidget/
    LotusPlannerWidget.swift     desktop widget
Shared/
    PlannerData.swift            models, themes, settings, storage
```

SwiftUI, WidgetKit, EventKit and UserNotifications. No external dependencies.

---

## FAQ

**Does it use up my ChatGPT or Claude quota?**
Yes, only when it reads a task description or suggests steps. Tasks without a description never call the AI. Nothing is billed to me and I never see your data or usage.

**Can I use it without an AI subscription?**
Yes. Everything works as a planner; descriptions simply aren't interpreted.

**Is it Arabic only?**
Yes, the interface is fully Arabic with right-to-left layout.

**Does it run on Intel Macs?**
Yes, from version 2.0 the release is universal.

---

## Contributing

Feedback and suggestions are welcome via [Issues](../../issues).

## License

[MIT](LICENSE). Use, modify, and distribute freely, keeping the license notice.
