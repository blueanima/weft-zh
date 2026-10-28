# Weft

**See where your day actually went, without sending it anywhere.**

Weft is a free, open-source time tracker that lives in your Mac's menu bar. It notices which app, window and website you're using, sorts the time into categories like Code, Meetings or Social Media, and draws your day as a few parallel streams of work.

Weft takes after [Rize](https://rize.io) but works from a different idea: people rarely do one thing at a time. You write code, check a doc, answer a message and go back to the code. So instead of a log of app switches, Weft shows the threads of work you kept coming back to.

## Why Weft

- **Native and small.** Weft is built with SwiftUI, so it looks and feels like the rest of macOS. The whole app is under 10 MB, with no Electron and no bundled browser.
- **Easy on your battery.** A native app already uses far less power than an Electron one. Weft is also event-driven instead of constantly polling your windows, so it stays idle until something actually changes.
- **Your data never leaves your Mac.** There's no account, no server and no analytics. Categories, summaries and reviews all come from Apple's on-device model, and your history stays in a folder on your Mac (see [Privacy](#privacy)).
- **Open source and free.** Weft is [MIT-licensed](LICENSE), with no subscription and no paid tier. You can read the code, change it and build it yourself.

## What you get

**A timeline of your day.** Time in the same category forms a *work stream* as long as you come back to it within 30 minutes. Streams of different categories overlap side by side, like events in a calendar. Each finished stream gets a one-sentence summary such as "Fixed the login redirect bug and reviewed two pull requests." Detours shorter than 10 minutes stay out of the way in the activity log below.

**Tracking you don't have to think about.** Start Weft once and forget about it. It records when you switch apps, windows or browser tabs, and stops counting when you step away (after 5 minutes without input, adjustable), close the lid or lock the screen. Calls and meetings keep counting even when you don't touch the keyboard.

**Categories that sort themselves.** Weft already knows a few hundred common apps and websites. Anything new is categorized by Apple Intelligence, once per app or site. If Weft gets one wrong, click the category in the log and choose:
- **Always for …**: remembers your choice for that app or site, including your past activity.
- **Only this entry**: fixes just that entry.

The **Review** page collects the AI's guesses so you can confirm them in one go.

**A Focus Score.** A 0–100 score for each day. It goes up with long stretches of focused work (25 minutes or more counts as deep work) and down with frequent context switching and time spent on distractions. Meetings don't count either way. Click the score to see how it was calculated.

**Focus, meeting and break sessions.** Start a timed session from the menu bar. Breaks can take over the screen, so you actually step away. When a focus session ends, Weft shows how focused you were and asks how it felt to you.

**A gentle distraction blocker.** During a focus session, if you stay on something distracting for 10 seconds (by default Social Media, Entertainment, Gaming, Shopping and Personal), Weft asks whether you meant to. You can go back to work, mark the app or site as *not a distraction*, or switch the blocker off for the rest of the session. You choose which categories count as distracting, and whether you get a full-screen prompt or just a notification.

**Breaks and healthy hours.** Weft reminds you to take a break after an hour of continuous work. Stepping away resets the timer, so it never nags you right after you get back. Set a daily target and Weft also lets you know when you reach it and when you're working too long.

**Daily and weekly reviews.** For any day, ask for a short on-device review with a suggestion for tomorrow. The weekly report compares tracked, focus, meeting and distracted time with the previous week, and shows time by category and your Focus Score trend. Click a day to open it.

## Privacy

- **What Weft records:** the app in front, its window title and, in supported browsers, the address of the current tab.
- **What it never records:** screenshots, keystrokes or the contents of your screen.
- **Where it goes:** nowhere. Categories, summaries and reviews are all produced on your Mac. Your data lives in `~/Library/Application Support/Weft/`.
- **What you control:** In **Settings → Tracking**, you can stop recording window titles, keep only the domain of URLs, and exclude specific apps and websites completely. Pause tracking any time from the menu bar or Settings.
- **Your data is yours:** You can export everything to CSV from **Settings → Data**. To erase your history, quit Weft and delete the folder above.

## Getting started

You'll need **macOS 26 or later**. Apple Intelligence is optional but recommended. Without it, Weft still categorizes the apps and sites it already knows and anything you've set yourself. Everything else waits on the Review page until you sort it.

1. Download the latest `Weft-<version>.dmg` from [Releases](https://github.com/tiann/weft/releases/latest).
2. Open it and drag **Weft** into **Applications**.
3. Open Weft from Applications. It's signed and notarized by Apple, so macOS opens it without warnings.

Weft appears in the menu bar. On first launch, it asks for Accessibility access. The other permissions come up the first time Weft needs them:

| Permission | What it's for |
| --- | --- |
| Accessibility | Reading window titles, so the timeline shows *which* document or project you were working in, not just the app |
| Automation (asked once per browser) | Reading the current tab's address in Safari, Chrome, Arc, Edge, Brave, Vivaldi, Opera, Dia and Comet. Other browsers are tracked by app and window title only |
| Notifications | Break reminders, session endings and the blocker's notification mode |

To start Weft automatically, turn on **Launch Weft at login** in **Settings → General**. To update, download the new DMG and replace the app. Your history and permissions carry over.

### Building from source

Install [Xcode](https://apps.apple.com/app/xcode/id497799835) and [Homebrew](https://brew.sh), then run:

```sh
brew install xcodegen
git clone https://github.com/tiann/weft.git
cd weft
xcodegen generate
xcodebuild -project Weft.xcodeproj -scheme Weft -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Weft.app
```

Your own builds aren't signed with a developer certificate, so macOS treats each one as a new app and drops its Accessibility permission. Grant it again in **System Settings → Privacy & Security → Accessibility**. Alternatively, sign with your own identity: copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and fill it in.

## Shortcuts and automation

Control Weft from Raycast, Alfred, Shortcuts or a script by opening these links:

| Link | Does |
| --- | --- |
| `weft://focus?minutes=50` | Start a focus session (leave out `minutes` to use your default) |
| `weft://meeting`, `weft://break` | Start a meeting or a break; both also accept `minutes` |
| `weft://stop` | End the current session |
| `weft://pause`, `weft://resume` | Pause or resume tracking |
| `weft://dashboard` | Open today in the main window |

For example, `open "weft://focus?minutes=25"` in Terminal.

## Troubleshooting

**Lots of entries are "Uncategorized".** Apple Intelligence is probably off or still downloading. Turn it on in System Settings, then open **Review** and click **Retry**. You can also categorize entries yourself from the log.

**Time I spent reading is missing.** Weft treats you as away after 5 minutes without keyboard or mouse input. If you often read or think for longer stretches, raise the threshold in **Settings → Tracking**.

## Contributing

Bug reports and pull requests are welcome. [AGENTS.md](AGENTS.md) covers the architecture, build commands and how to run the tests.
