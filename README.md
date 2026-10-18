# Leftovers

A tiny Mac menu-bar app that spots things Claude left running and draining your battery, then stops them with one click.

<img src="images/menu.png" width="400" alt="The Leftovers dropdown: a stuck job flagged red with Stop, Keep and Snooze buttons">

## Why

Claude Code often starts background work: builds, video encodes, dev servers, iPhone simulators. When a session ends, some of that work can keep running with nothing watching it. Leftovers was written after a video encode had been stuck for **two days** at full power, two simulators had been running for over a day, and the Claude app had been stopping the Mac from sleeping for 55 hours. Nothing had warned about any of it.

## What it watches

| Section | What it means |
|---|---|
| **Left behind** | Its Claude session is gone, but the process is still running. Shows which session left it. |
| **Keeping your Mac awake** | Claude (or something it started) is stopping the Mac from sleeping. |
| **Simulators** | Booted iPhone/iPad simulators, and which app each one is running. |
| **Running in a Claude session** | Busy work owned by a session that's still open. Listed for your information; never flagged. |
| **Started by the Claude app** | Preview/dev servers the app started, with how many browsers are connected. |
| **The Claude app itself** | For comparison. |

Every row shows its **battery cost** as a share of your battery per hour (e.g. `8%/h`), worked out from the energy macOS measures for each process.

## When it warns you

It warns you only when something is both **unowned** (its Claude session has ended) and **unused** (not making progress, nobody connected, not being looked at). Busy is not enough on its own.

| | When | Example |
|---|---|---|
| 🔴 | Working hard for 30+ min but its output files haven't changed for 30+ min | "ffmpeg looks stuck" |
| 🔴 | Claude has kept the Mac awake 2+ h on battery, though no session has worked for 30 min | "Claude is keeping your Mac awake" |
| 🟠 | Still busy 10+ min after its session ended | "A leftover from Claude is still running" |
| 🟠 | A simulator running 2+ h without being used | "iPhone 17 is running unused" |
| ⚪ | A dev server nobody has connected to for 1+ h | shown in the menu only |

On battery, all waits are cut in half. Each problem is announced once, with **Stop**, **Keep running** and **Remind me in an hour** buttons. When you unplug, you get one summary of anything still running.

**It never stops anything without a click.** Stop asks the process to quit, waits 5 seconds, then forces it if needed. It also stops the script that started it, so nothing starts again. **Keep** is remembered for that project and command.

## Privacy & permissions

- Fully offline. It reads the process list, battery info and the Claude app's session titles on your Mac. Nothing leaves the computer.
- The only permission it asks for is the standard one for notifications.
- It only looks at processes that came from Claude, or that run inside Claude's scratch folders or your project folders (Settings → Project folders; default `~/Desktop/claude`). It never touches your normal apps.
- It uses about 0.02% of the battery per hour itself (shown in the footer). It checks every minute on battery and every 3 minutes when plugged in.

<img src="images/settings.png" width="400" alt="Settings: open at login, notifications, project folders, kept list">

## Build

Needs the Swift toolchain (Xcode or Command Line Tools); no Xcode project.

```bash
./build.sh      # builds Leftovers.app, installs it to /Applications and launches it
swift test      # alarm-rule and classification tests
```

Testing helpers: `Leftovers --once` prints one scan as JSON, `Leftovers --stop <title>` stops a matching leftover, and `defaults write com.danielryan.Leftovers ruleSpeedup -float 60` makes every wait 60× shorter (delete it afterwards).

## License

MIT
