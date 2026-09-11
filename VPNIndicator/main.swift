import AppKit
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
    private var loadingTimer: Timer?
    private var spinnerDisplayLink: AnyObject?
    private var spinnerBadgeColor: NSColor?
    private var animationActivity: NSObjectProtocol?
    private var loadingPollTimer: Timer?
    private var loadingTimeoutWork: DispatchWorkItem?
    private var lastStatus: VPNStatus?
    private let checkQueue = DispatchQueue(label: "com.example.vpnindicator.check", qos: .utility)

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

        let toggleItem = NSMenuItem(title: "Toggle VPN", action: #selector(toggleVPN), keyEquivalent: "t")
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
        // Resolve the DeepSeek badge colour once per animation instead of
        // rebuilding a UTC Calendar on every frame (60x/second of wasted work).
        spinnerBadgeColor = Self.deepSeekColor(for: DeepSeekPricing.currentPeriod())
        statusItem.button?.image = Self.loadingImage(
            startAngleDeg: 0,
            sweepDeg: 20,
            deepSeekColor: spinnerBadgeColor)
        statusItem.button?.toolTip = expectedTargetConnected ? "Connecting…" : "Disconnecting…"
        statusMenuItem?.title = expectedTargetConnected ? "Connecting…" : "Disconnecting…"

        // A menu bar accessory app is App-Napped, which coalesces and throttles
        // its timers -- the usual reason such spinners look choppy. Hold a
        // user-initiated activity for the duration of the animation.
        if animationActivity == nil {
            animationActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated,
                reason: "VPN toggle spinner")
        }

        stopSpinnerAnimation()

        // Drive frames from the display's refresh cadence when available so they
        // land on vsync instead of beating against it; a free-running 60 Hz timer
        // stays as the fallback for older systems.
        if #available(macOS 14.0, *), let button = statusItem.button {
            let link = button.displayLink(target: self, selector: #selector(advanceSpinner(_:)))
            // Use the display's native refresh instead of hard-capping at 60 Hz.
            // ProMotion panels run at 120 Hz, which halves the rotation step per
            // frame and visibly smooths the spin. The system clamps this to what
            // the screen actually supports, so it stays correct on 60 Hz displays.
            let maxFPS = Float(NSScreen.main?.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maxFPS, preferred: maxFPS)
            link.add(to: .main, forMode: .common)
            spinnerDisplayLink = link
        } else {
            let spinnerTimer = Timer(timeInterval: 1.0 / 60.0,
                                     target: self,
                                     selector: #selector(advanceSpinner(_:)),
                                     userInfo: nil,
                                     repeats: true)
            spinnerTimer.tolerance = 0
            RunLoop.main.add(spinnerTimer, forMode: .common)
            loadingTimer = spinnerTimer
        }

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

    /// Same drawing and the same maths as before -- only the frame source changed.
    @objc private func advanceSpinner(_ sender: Any?) {
        let t = Date().timeIntervalSinceReferenceDate - loadingStartTime
        let p = (t / 1.6) * 2 * .pi
        let startDeg = CGFloat((t / 1.6) * 1.2 * 360)
        let sweepDeg = CGFloat(20 + 270 * (0.5 - 0.5 * cos(p)))
        statusItem.button?.image = Self.loadingImage(
            startAngleDeg: startDeg,
            sweepDeg: sweepDeg,
            deepSeekColor: spinnerBadgeColor)
    }

    private func stopSpinnerAnimation() {
        loadingTimer?.invalidate(); loadingTimer = nil
        if #available(macOS 14.0, *) {
            (spinnerDisplayLink as? CADisplayLink)?.invalidate()
        }
        spinnerDisplayLink = nil
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

    @objc private func quit() {
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

    /// Google-style spinner: a single arc that grows and shrinks while rotating.
    private static func loadingImage(startAngleDeg: CGFloat,
                                     sweepDeg: CGFloat,
                                     deepSeekColor: NSColor?) -> NSImage {
        let side: CGFloat = 20
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let dotRect = rect.insetBy(dx: 4, dy: 4)
            NSColor.labelColor.setStroke()
            let path = NSBezierPath()
            path.appendArc(withCenter: NSPoint(x: dotRect.midX, y: dotRect.midY),
                           radius: dotRect.width / 2,
                           startAngle: startAngleDeg,
                           endAngle: startAngleDeg + sweepDeg,
                           clockwise: true)
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.stroke()
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
