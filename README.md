# VPN Indicator (macOS menu bar)

A tiny macOS menu bar app that shows a **black filled dot** when any VPN is connected and a
**black circle** (hollow) when no VPN is connected. **Click the dot to toggle your VPN**
on and off (left-click toggles, right-click shows the menu).

It watches for system network changes via SystemConfiguration (`SCDynamicStore`) and, when a
change is detected, checks `scutil --nc list`. This is event-driven rather than polling, so it
works with any VPN that macOS manages (system VPN services, personal VPNs, etc.).

## Build

Requires the macOS Command Line Tools (Swift):

```bash
./build.sh
```

This produces `build/VPNIndicator.app`.

## Run

```bash
open build/VPNIndicator.app
```

Or double-click `VPNIndicator.app` in Finder. Since it runs as a menu bar accessory
(`LSUIElement`), it has no Dock icon — you'll see a small dot in the top menu bar.

- **Left-click** the dot toggles the target VPN (connect if disconnected, disconnect if connected).
- **Right-click** (or ⌃-click) opens the menu: Toggle VPN, Refresh Now, Quit.
- **⌘⇧P** toggles the target VPN from **anywhere** (a true system-wide shortcut — see below).
- The tooltip shows which VPNs are currently connected and the DeepSeek Peak/Off-Peak state.

A **4×4 px white round dot** in the top-right corner of the status icon shows DeepSeek's current
**Peak** (`P`) / **Off-Peak** (`O/P`) pricing period:
- **Dot present** = Off-Peak (`O/P`)
- **No dot** = Peak (`P`)

### DeepSeek Peak / Off-Peak schedule

The indicator uses DeepSeek's official pricing schedule
([DeepSeek API docs → Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing)):

> Off-peak rates are half of the peak rates. **Peak hours are 01:00–04:00 and 06:00–10:00 UTC,
> Monday through Friday** (all other hours are off-peak).

So the dot shows:
- **Dot present** — **Off-Peak** (everything except the windows below, including the entire weekend)
- **No dot** — **Peak** (Mon–Fri, 01:00–04:00 or 06:00–10:00 UTC)

The state is derived from the current UTC time (the window is defined in UTC, not local time).
A dedicated timer re-evaluates it **every 60 seconds** and redraws the icon from the last known VPN
status (without re-running `scutil`), so the dot flips almost immediately at each peak/off-peak
boundary. The VPN status itself is refreshed on network-change events plus a 60s fallback poll.

## How it decides

- It runs `scutil --nc list` and looks for any line containing `(Connected)`.
- Black filled dot = at least one VPN is connected (the connected VPN names appear in the tooltip).
- Black hollow circle = no VPN is connected.

## Global shortcut: ⌘⇧P

Pressing **⌘⇧P** while any app is frontmost toggles the target VPN — exactly the same code path as
left-clicking the menu bar dot (it is guarded, so a second press while a toggle is already in flight
is ignored).

It is registered in `installGlobalHotKey()` with Carbon's `RegisterEventHotKey`, which is the only
approach that works for a menu bar accessory app **without asking for any permission**:

| Approach | Works globally? | Permission needed |
| --- | --- | --- |
| `NSMenuItem.keyEquivalent` | ✗ — the app is never the active app, so its menu is never consulted | none |
| `NSEvent.addGlobalMonitorForEvents` | ✓ | **Accessibility** (plus Input Monitoring on newer macOS) |
| `RegisterEventHotKey` (used here) | ✓ | none |

Registration problems are reported on **stderr** (“registered global hot key ⌘⇧P” / “could not register ⌘⇧P”).
Launchd discards an app’s stderr, so to see them run the binary from a terminal:

```bash
~/Applications/VPNIndicator.app/Contents/MacOS/VPNIndicator
```

If several copies of the app are running, only **one** of them answers ⌘⇧P. Each instance tries to take
an exclusive lock on `~/Library/Application Support/VPNIndicator/hotkey.lock` at launch, and only the lock
owner registers the shortcut; the others stand by and take over if the owner exits (the kernel releases
the lock when its owner dies). A clean **Quit** hands the shortcut over immediately; a crash or `kill`
can leave it unowned for up to the 3-minute retry interval — deliberately slow so the standby check
does not keep touching the disk. This is necessary because macOS delivers a registered
hot key to *every* process that registered it — without the lock, one press would toggle the VPN once
per running copy. The click-toggle keeps working even if registration fails.

## Customizing

### Watch a specific VPN only

In `VPNIndicator/main.swift`, change the `check()` method to match only your VPN name,
for example:

```swift
return VPNStatus(connected: names.contains("My VPN"),
                 connectedNames: names.filter { $0 == "My VPN" })
```

### Which VPN gets toggled

The click-toggle targets the VPN named in the `targetVPNName` constant at the top of
`VPNIndicator/main.swift` (default `"Happ Plus"`). Change it to the exact name shown by
`scutil --nc list` for your VPN.

Toggling uses the built-in `scutil --nc start/stop "<name>"` — the same mechanism tested
and verified on this machine — so no Shortcuts or extra permissions are needed.

While a toggle is in flight, the dot becomes a **spinning arc** and keeps spinning until the
VPN actually reaches its new state (checked via the same event-driven watcher plus a 1s poll,
with a 20s safety timeout).

### How it detects changes

The app subscribes to SystemConfiguration's `SCDynamicStore` and re-checks whenever the system
network state changes (interface up/down, default-route change, service state change) — all of
which happen on VPN connect/disconnect. A slow fallback timer (60s) still runs as a safety net
in case a change is ever missed.

To change the fallback interval, edit the `Timer.scheduledTimer(timeInterval: 60.0, ...)` call.

## Auto-start at login

The app is installed to `~/Applications/VPNIndicator.app` and registered as a
LaunchAgent (`~/Library/LaunchAgents/com.example.vpnindicator.plist`), so it
starts automatically at login and restarts automatically if it ever crashes.

To **stop/disable** auto-start:

```bash
launchctl unload ~/Library/LaunchAgents/com.example.vpnindicator.plist
```

To **re-enable** it:

```bash
launchctl load ~/Library/LaunchAgents/com.example.vpnindicator.plist
```

To **uninstall** completely:

```bash
launchctl unload ~/Library/LaunchAgents/com.example.vpnindicator.plist
rm ~/Library/LaunchAgents/com.example.vpnindicator.plist
rm -rf ~/Applications/VPNIndicator.app
```

> Note: after rebuilding with `./build.sh`, replace the installed copy with
> `ditto build/VPNIndicator.app ~/Applications/VPNIndicator.app`
> (or `rm -rf ~/Applications/VPNIndicator.app && cp -R build/VPNIndicator.app ~/Applications/VPNIndicator.app`).
> Plain `cp -R` into an existing bundle **nests** the new app inside the old one,
> so the LaunchAgent keeps launching the stale binary.
