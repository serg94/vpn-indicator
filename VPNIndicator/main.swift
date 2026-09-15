import AppKit
import Carbon.HIToolbox
import Foundation
import QuartzCore
import SystemConfiguration

/// The VPN the indicator toggles on click (name as shown by `scutil --nc list`).
private let targetVPNName = "Happ Plus"

/// Snapshot of the current VPN connectivity.
struct VPNStatus {
    let connected: Bool
    let connectedNames: [String]
}

/// Checks VPN status by querying the system's network configuration via `scutil`.
enum VPNStatusChecker {
    static func check() -> VPNStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--nc", "list"]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return VPNStatus(connected: false, connectedNames: [])
        }
        process.waitUntilExit()

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return VPNStatus(connected: false, connectedNames: [])
        }

        var names: [String] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard line.contains("(Connected)") else { continue }
            if let name = Self.quotedName(in: line) {
                names.append(name)
            }
        }

        return VPNStatus(connected: !names.isEmpty, connectedNames: names)
    }

    /// Extracts the first double-quoted string from a line (the user-visible VPN name).
    private static func quotedName(in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""([^"]+)""#) else {
            return nil
        }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: nsRange),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[range])
    }
}

/// Determines whether DeepSeek is currently in a Peak or Off-Peak pricing period.
///
/// Source: DeepSeek API docs → Models & Pricing → footnote.
/// https://api-docs.deepseek.com/quick_start/pricing
///
/// Official schedule (as of Aug 2026): off-peak rates are half the peak rates.
/// Peak hours are **01:00–04:00** and **06:00–10:00 UTC, Monday through Friday**;
/// all other hours (including the whole weekend) are off-peak.
enum DeepSeekPricing {
    enum Period {
        case peak    // P — Peak
        case offPeak // O/P — Off-Peak
    }

    static func currentPeriod(now: Date = Date()) -> Period {
        // Evaluate the schedule in UTC (DeepSeek prices are defined per UTC).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: now)

        guard let weekday = c.weekday, // 1 = Sunday … 7 = Saturday
              let hour = c.hour,
              let minute = c.minute else {
            return .peak
        }

        // Peak only Monday–Friday (weekday 2…6); weekends are always off-peak.
        let isWeekday = (2...6).contains(weekday)
        guard isWeekday else { return .offPeak }

        let minutes = hour * 60 + minute
        let inMorningWindow = minutes >= 1 * 60 && minutes < 4 * 60   // 01:00–04:00
        let inLateWindow   = minutes >= 6 * 60 && minutes < 10 * 60   // 06:00–10:00
        return (inMorningWindow || inLateWindow) ? .peak : .offPeak
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem?
    private var statusMenu: NSMenu?
    private var timer: Timer?
    private var deepSeekTimer: Timer?
    private var dynamicStore: SCDynamicStore?
    private var pendingRefresh: DispatchWorkItem?
    private var toggleInProgress = false
    private var expectedTargetConnected = false
    private var loadingStartTime: TimeInterval = 0
    private var spinnerArcLayer: CAShapeLayer?
    private var spinnerBadgeColor: NSColor?
    private var animationActivity: NSObjectProtocol?
    private var loadingPollTimer: Timer?
    private var loadingTimeoutWork: DispatchWorkItem?
    private var lastStatus: VPNStatus?
    private let checkQueue = DispatchQueue(label: "com.example.vpnindicator.check", qos: .utility)
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    /// Kept open for the lifetime of the process: the exclusive lock on this
    /// file is what makes this instance the one that answers ⌘⇧P.
    /// -1 means this instance does not own the shortcut.
    private var hotKeyLockDescriptor: Int32 = -1
    private var hotKeyStandbyTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a menu bar accessory: no Dock icon, no app menu.
        NSApplication.shared.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Self.indicatorImage(
                filled: false,
                color: .labelColor,
                deepSeekColor: Self.deepSeekColor(for: DeepSeekPricing.currentPeriod()))
            button.toolTip = "VPN not connected"
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        let statusTitleItem = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
        statusTitleItem.isEnabled = false
        menu.addItem(statusTitleItem)
        self.statusMenuItem = statusTitleItem

        menu.addItem(.separator())

        // The real (system-wide) shortcut is registered with Carbon in
        // installGlobalHotKey(); this key equivalent only exists so the menu
        // displays ⌘⇧P next to the item.
        let toggleItem = NSMenuItem(title: "Toggle VPN", action: #selector(toggleVPN), keyEquivalent: "p")
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        toggleItem.target = self
        menu.addItem(toggleItem)

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusMenu = menu

        refreshNow()
        startMonitoringNetworkChanges()
        installGlobalHotKey()

        // Slow fallback poll: the dynamic store handles the normal case,
        // but keep a periodic safety net in case a change is ever missed.
        timer = Timer.scheduledTimer(timeInterval: 60.0,
                                     target: self,
                                     selector: #selector(refreshNow),
                                     userInfo: nil,
                                     repeats: true)

        // Dedicated time check so the DeepSeek Peak/Off-Peak dot stays current
        // as the clock crosses the peak/off-peak boundary times. It only
        // re-evaluates the time and redraws the icon from the last known VPN
        // status — it does not re-run `scutil`.
        deepSeekTimer = Timer.scheduledTimer(timeInterval: 60.0,
                                             target: self,
                                             selector: #selector(updateDeepSeekIndicator),
                                             userInfo: nil,
                                             repeats: true)
    }

    @objc private func refreshNow() {
        checkQueue.async { [weak self] in
            let status = VPNStatusChecker.check()
            DispatchQueue.main.async {
                self?.apply(status)
            }
        }
    }

    /// Re-evaluates the DeepSeek Peak/Off-Peak state from the current time and
    /// redraws the icon using the last known VPN status (no `scutil` call).
    /// Skipped while a VPN toggle is in flight so it never interrupts the spinner.
    @objc private func updateDeepSeekIndicator() {
        guard !toggleInProgress, let status = lastStatus else { return }
        render(status)
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            showMenu(sender)
        } else {
            toggleVPN()
        }
    }

    private func showMenu(_ sender: NSStatusBarButton) {
        guard let menu = statusMenu else { return }
        statusItem.menu = menu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleVPN() {
        guard !toggleInProgress else { return }
        toggleInProgress = true

        checkQueue.async { [weak self] in
            guard let self = self else { return }
            let status = VPNStatusChecker.check()
            let currentlyConnected = status.connectedNames.contains(targetVPNName)
            let action = currentlyConnected ? "stop" : "start"

            DispatchQueue.main.async {
                self.expectedTargetConnected = !currentlyConnected
                self.beginLoadingUI()
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
            process.arguments = ["--nc", action, targetVPNName]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self.endLoading()
                }
            }
        }
    }

    private func beginLoadingUI() {
        loadingStartTime = Date().timeIntervalSinceReferenceDate
        // The badge is a static image; the spinning arc is a Core Animation layer
        // (see startSpinnerAnimation). Nothing about the animation runs on our
        // main thread any more, so status polling and dynamic-store handling can
        // no longer stall or skip a frame.
        spinnerBadgeColor = Self.deepSeekColor(for: DeepSeekPricing.currentPeriod())
        statusItem.button?.image = Self.badgeImage(deepSeekColor: spinnerBadgeColor)
        statusItem.button?.toolTip = expectedTargetConnected ? "Connecting…" : "Disconnecting…"
        statusMenuItem?.title = expectedTargetConnected ? "Connecting…" : "Disconnecting…"

        // Held so App Nap cannot throttle the 1 s status poll while the spinner is
        // up; the arc itself no longer depends on us at all.
        if animationActivity == nil {
            animationActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated,
                reason: "VPN toggle spinner")
        }

        startSpinnerAnimation()

        loadingPollTimer?.invalidate()
        loadingPollTimer = Timer.scheduledTimer(timeInterval: 1.0,
                                                target: self,
                                                selector: #selector(refreshNow),
                                                userInfo: nil,
                                                repeats: true)

        loadingTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.endLoading()
        }
        loadingTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0, execute: work)
    }

    /// Width/height of the drawn icon, matching the settled glyph images.
    private static let iconSide: CGFloat = 20

    /// Sweep of the spinner arc `t` seconds into the cycle, as a fraction of a
    /// full circle. Identical maths to the previous image-based spinner.
    private static func sweepFraction(at t: Double) -> CGFloat {
        let p = (t / 1.6) * 2 * .pi
        return CGFloat((20 + 270 * (0.5 - 0.5 * cos(p))) / 360.0)
    }

    /// Hands the spinner to Core Animation: one shape layer whose stroke sweeps
    /// while the layer rotates. Core Animation interpolates on the render server,
    /// so the spin cannot be stalled by anything the app does on the main thread.
    private func startSpinnerAnimation() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        stopSpinnerAnimation()

        let layer = CAShapeLayer()
        layer.frame = CGRect(x: (button.bounds.width - Self.iconSide) / 2,
                             y: (button.bounds.height - Self.iconSide) / 2,
                             width: Self.iconSide,
                             height: Self.iconSide)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: Self.iconSide / 2, y: Self.iconSide / 2),
                    radius: 6,
                    startAngle: 0,
                    endAngle: .pi * 2,
                    clockwise: true)
        layer.path = path
        layer.fillColor = nil
        layer.lineWidth = 2
        layer.lineCap = .round
        layer.strokeStart = 0
        layer.strokeEnd = Self.sweepFraction(at: 0)

        // Rasterise at the screen's scale, otherwise the vector arc is drawn at
        // 1x and upscaled, which shows up as a fatter, blurry stroke.
        layer.contentsScale = button.layer?.contentsScale
            ?? NSScreen.main?.backingScaleFactor ?? 2

        // Resolve labelColor against the menu bar's appearance, not the app's.
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.strokeColor = NSColor.labelColor.cgColor
        }

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0.0
        rotation.toValue = 2 * Double.pi
        rotation.duration = 360.0 / 270.0   // the original advanced startDeg 270 deg/s
        rotation.repeatCount = .infinity
        layer.add(rotation, forKey: "rotation")

        let steps = 64
        let sweep = CAKeyframeAnimation(keyPath: "strokeEnd")
        sweep.values = (0...steps).map { Self.sweepFraction(at: Double($0) / Double(steps) * 1.6) }
        sweep.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        sweep.duration = 1.6
        sweep.repeatCount = .infinity
        sweep.calculationMode = .linear
        layer.add(sweep, forKey: "sweep")

        button.layer?.addSublayer(layer)
        spinnerArcLayer = layer
    }

    private func stopSpinnerAnimation() {
        spinnerArcLayer?.removeAllAnimations()
        spinnerArcLayer?.removeFromSuperlayer()
        spinnerArcLayer = nil
    }

    private func clearLoadingUI() {
        toggleInProgress = false
        stopSpinnerAnimation()
        loadingPollTimer?.invalidate(); loadingPollTimer = nil
        loadingTimeoutWork?.cancel(); loadingTimeoutWork = nil
        spinnerBadgeColor = nil
        if let activity = animationActivity {
            ProcessInfo.processInfo.endActivity(activity)
            animationActivity = nil
        }
    }

    private func endLoading() {
        clearLoadingUI()
        refreshNow()
    }

    /// Subscribes to SystemConfiguration network state changes instead of polling.
    private func startMonitoringNetworkChanges() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let store = SCDynamicStoreCreate(
            nil,
            "VPNIndicator" as CFString,
            { _, _, info in
                guard let info = info else { return }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
                delegate.handleNetworkChange()
            },
            &context
        ) else {
            return // Fallback timer still keeps us working.
        }

        let keys: CFArray = [
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6",
            "State:/Network/Interface",
        ] as CFArray

        let patterns: CFArray = [
            "State:/Network/Interface/.*",
            "State:/Network/Service/.*",
            "State:/Network/Service/.*/.*",
            "State:/Network/Connection/.*",
            "State:/Network/Connection/.*/.*",
        ] as CFArray

        _ = SCDynamicStoreSetNotificationKeys(store, keys, patterns)
        _ = SCDynamicStoreSetDispatchQueue(store, checkQueue)
        dynamicStore = store
    }

    private func handleNetworkChange() {
        // A single VPN connect/disconnect triggers a burst of dynamic-store
        // updates; debounce so we re-check just once per burst.
        debouncedRefresh()
    }

    private func debouncedRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshNow()
        }
        pendingRefresh = work
        checkQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func apply(_ status: VPNStatus) {
        if toggleInProgress {
            let targetConnected = status.connectedNames.contains(targetVPNName)
            if targetConnected == expectedTargetConnected {
                clearLoadingUI()
            } else {
                // Still transitioning; keep the spinner until the state actually changes.
                return
            }
        }
        render(status)
    }

    private func render(_ status: VPNStatus) {
        lastStatus = status
        let period = DeepSeekPricing.currentPeriod()
        let deepSeekColor = Self.deepSeekColor(for: period)
        let image = status.connected
            ? Self.indicatorImage(filled: true, color: .labelColor, deepSeekColor: deepSeekColor)
            : Self.indicatorImage(filled: false, color: .labelColor, deepSeekColor: deepSeekColor)
        statusItem.button?.image = image

        let deepSeekLabel = period == .peak ? "Peak" : "Off-Peak"
        if status.connected {
            let names = status.connectedNames.joined(separator: ", ")
            statusItem.button?.toolTip = "Connected: \(names) · DeepSeek \(deepSeekLabel)"
            statusMenuItem?.title = "Connected: \(names)"
        } else {
            statusItem.button?.toolTip = "VPN not connected · DeepSeek \(deepSeekLabel)"
            statusMenuItem?.title = "Not connected"
        }
    }

    // MARK: - Global hot key (⌘⇧P)

    /// Decides which instance answers ⌘⇧P, then registers it there.
    ///
    /// macOS lets *every* process register the same hot key and then delivers the
    /// press to all of them, so N copies of the app would run the toggle N times
    /// per press. Ownership is settled here instead: an exclusive advisory lock
    /// (flock) on a file in Application Support marks the single instance allowed
    /// to register the hot key. The kernel drops that lock automatically when its
    /// owner exits, so every other instance retries every few minutes and
    /// the first one to win takes the shortcut over.
    ///
    /// Carbon remains the registration mechanism because it is the only API that
    /// gives an accessory (LSUIElement) app a true global shortcut with no TCC
    /// permission: a menu key equivalent is never consulted since this app is
    /// never the active application, and NSEvent.addGlobalMonitorForEvents needs
    /// the Accessibility permission.
    private func installGlobalHotKey() {
        guard let descriptor = openHotKeyLockFile() else {
            // No Application Support directory: run anyway. A working shortcut
            // matters more than a unique one.
            registerGlobalHotKey()
            return
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            hotKeyLockDescriptor = descriptor   // stay open: the lock lives with the fd
            registerGlobalHotKey()
            return
        }

        close(descriptor)
        NSLog("VPNIndicator: another instance owns ⌘⇧P, standing by")
        hotKeyStandbyTimer = Timer.scheduledTimer(timeInterval: Self.hotKeyStandbyInterval,
                                                  target: self,
                                                  selector: #selector(retryHotKeyOwnership),
                                                  userInfo: nil,
                                                  repeats: true)
    }

    /// Runs in a standby instance: takes the shortcut over once the owner is gone.
    @objc private func retryHotKeyOwnership() {
        guard let descriptor = openHotKeyLockFile() else { return }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return
        }
        hotKeyLockDescriptor = descriptor
        hotKeyStandbyTimer?.invalidate()
        hotKeyStandbyTimer = nil
        NSLog("VPNIndicator: took over ⌘⇧P from a previous instance")
        registerGlobalHotKey()
    }

    /// Opens (creating it if needed) the file whose exclusive lock means "this
    /// process is the one that answers ⌘⇧P". Nil when it cannot be opened.
    private func openHotKeyLockFile() -> Int32? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else {
            return nil
        }
        let folder = support.appendingPathComponent("VPNIndicator", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.appendingPathComponent("hotkey.lock").path,
                              O_CREAT | O_RDWR,
                              0o644)
        return descriptor >= 0 ? descriptor : nil
    }

    /// How often a standby instance re-tries for the shortcut. Kept deliberately
    /// slow: the retry touches the filesystem (open + flock), and nothing about
    /// the shortcut is urgent enough to justify running it every couple of
    /// seconds. A clean Quit releases the lock immediately, so this interval is
    /// only ever paid after a crash or a kill.
    private static let hotKeyStandbyInterval: TimeInterval = 180.0   // 3 min

    /// Installs the Carbon hot key. Only the lock owner should call this.
    private func registerGlobalHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let handlerStatus = InstallEventHandler(GetEventDispatcherTarget(),
                                                Self.hotKeyHandler,
                                                1,
                                                &eventType,
                                                Unmanaged.passUnretained(self).toOpaque(),
                                                &hotKeyHandlerRef)
        guard handlerStatus == noErr else {
            NSLog("VPNIndicator: hot key handler install failed (\(handlerStatus))")
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_P),
                                         Self.hotKeyModifiers,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &hotKeyRef)
        if status == noErr {
            // Diagnostics go to stderr; launchd discards an app's stderr, so run
            // the binary from a terminal to see this line.
            NSLog("VPNIndicator: registered global hot key ⌘⇧P (hot key owner)")
        } else {
            // e.g. another app (or the system) already owns ⌘⇧P.
            NSLog("VPNIndicator: could not register ⌘⇧P (\(status))")
        }
    }

    /// Four-character code 'VPNI' — identifies our hot key in the event callback.
    private static let hotKeySignature: OSType = 0x56504E49

    /// Carbon modifier mask for ⌘⇧ (cmdKey | shiftKey).
    private static let hotKeyModifiers = UInt32(cmdKey | shiftKey)

    /// C event callback. It cannot be a closure over `self` (C function pointers
    /// cannot capture), so the delegate is handed over through `userData`.
    /// Carbon dispatches this on the main thread, which is where toggleVPN() lives.
    private static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }

        var hotKeyID = EventHotKeyID()
        let err = GetEventParameter(event,
                                    EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID),
                                    nil,
                                    MemoryLayout<EventHotKeyID>.size,
                                    nil,
                                    &hotKeyID)
        guard err == noErr, hotKeyID.signature == AppDelegate.hotKeySignature else { return noErr }

        let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
        delegate.toggleVPN()
        return noErr
    }

    @objc private func quit() {
        // Releasing the lock lets another instance pick up ⌘⇧P at once
        // instead of on its next 3-minute retry.
        if hotKeyLockDescriptor >= 0 {
            close(hotKeyLockDescriptor)
            hotKeyLockDescriptor = -1
        }
        NSApplication.shared.terminate(nil)
    }

    /// Draws the status glyph: a filled dot when connected, a hollow circle when not.
    /// The glyph is the original full size (inset 3); the small DeepSeek badge in
    /// the top-right corner is drawn small enough not to intersect it.
    private static func indicatorImage(filled: Bool,
                                       color: NSColor,
                                       deepSeekColor: NSColor?) -> NSImage {
        let side: CGFloat = 20
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let dotRect = rect.insetBy(dx: 3, dy: 3)
            if filled {
                color.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            } else {
                color.setStroke()
                let path = NSBezierPath(ovalIn: dotRect)
                path.lineWidth = 2
                path.stroke()
            }
            if let deepSeekColor {
                Self.drawDeepSeekBadge(in: rect, color: deepSeekColor)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Just the DeepSeek badge, used while the arc is drawn by Core Animation
    /// instead of being baked into a single spinner image.
    private static func badgeImage(deepSeekColor: NSColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: iconSide, height: iconSide), flipped: false) { rect in
            if let deepSeekColor {
                Self.drawDeepSeekBadge(in: rect, color: deepSeekColor)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Returns the color for the DeepSeek state dot (white), or `nil` when no dot
    /// should be shown (Peak). The dot is only shown during **Off-Peak** hours
    /// (dot present = off-peak, dot absent = peak).
    private static func deepSeekColor(for period: DeepSeekPricing.Period) -> NSColor? {
        guard period == .offPeak else { return nil }
        return .white
    }

    /// Draws a 4×4 px DeepSeek state dot as a white circle in the top-right corner,
    /// flush against the icon's corner so it stays clear of the VPN glyph.
    private static func drawDeepSeekBadge(in rect: NSRect, color: NSColor) {
        let side = rect.width
        let size: CGFloat = 4
        let badgeRect = NSRect(x: side - size, y: side - size, width: size, height: size)
        color.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
