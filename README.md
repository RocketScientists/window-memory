# Window Memory

A small native macOS menu-bar app that remembers window size and position for each display setup (for example "laptop only" or "laptop + external") and restores them when you switch. It needs only Apple's built-in Command Line Tools (`swiftc`); nothing else is installed.

## Install

```bash
./install.sh
```

This builds `build/WindowMemory.app`, copies it to `~/Applications`, and registers a LaunchAgent so it starts at login. When macOS asks, allow **Window Memory** under System Settings → Privacy & Security → **Accessibility**. It usually starts working within a few seconds; if it doesn't, choose Quit Window Memory from its menu, then run `./install.sh` again.

> **After a rebuild:** the app is signed ad hoc, so each rebuild looks like a new app to macOS. If it stops moving windows after you run `./install.sh` again, remove Window Memory from the Accessibility list, then add it back (or toggle it off and on).

## How it works

- Every 3 s it records each window's frame as fractions of its screen, keyed by the current display setup (the set of connected display UUIDs).
- When the display setup changes, it waits 2 s for macOS to finish moving windows, then:
  - restores the saved layout for the new setup, if one exists, or
  - scales windows proportionally from the setup you just left (the first time you use a setup).
- When a window moves to another display (you drag it there, or Stage Manager moves it), it's resized to the same fraction of that display, so it isn't tiny on the big screen or oversized on the laptop. It's kept where you dropped it. Set `scaleOnScreenMove = false` to turn this off.
- Windows opened later (after a switch, an app relaunch or a reboot) get their saved frame a few seconds after they appear, matched by title, or by app when it has only one window. A window is never placed exactly on top of another window of the same app. Set `restoreNewWindows = false` to turn this off.
- Stage Manager: windows in background stages that ignore the move are restored again when their app is next activated.
- Layouts are stored in `~/Library/Application Support/WindowMemory/layouts.json`.

## Menu bar and hotkeys

Click the window icon in the menu bar, or use:

| Keys | Action |
|---|---|
| Ctrl+Opt+Cmd+S | Save the current layout now |
| Ctrl+Opt+Cmd+R | Re-apply the saved layout |
| Ctrl+Opt+Cmd+X | Forget the saved layout for this display setup |

After a restore, a short note appears next to the icon: `↺ n` means *n* windows were restored, and `⤢ n` means *n* windows were scaled for a new setup.

## Troubleshooting

```bash
build/WindowMemory.app/Contents/MacOS/WindowMemory --status
```

```bash
tail -f ~/Library/Logs/WindowMemory.log
```

Tune `saveInterval`, `settleDelay` and `ignoredBundleIDs` at the top of `WindowMemory.swift`, then run `./install.sh` again.

## Uninstall

```bash
./uninstall.sh
```

Add `--purge` to also delete the saved layouts and reset the Accessibility permission.
