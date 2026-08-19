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
- The tooltip shows which VPNs are currently connected.

## How it decides

- It runs `scutil --nc list` and looks for any line containing `(Connected)`.
- Black filled dot = at least one VPN is connected (the connected VPN names appear in the tooltip).
- Black hollow circle = no VPN is connected.

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
