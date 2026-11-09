import AppKit

final class BlueBarDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let defaults = UserDefaults.standard
    let refreshChoices = [(5, "5s"), (20, "20s"), (30, "30s"), (60, "1m"), (120, "2m")]
    let demo = CommandLine.arguments.contains("--demo")
    private var showMenuAfterLaunch = CommandLine.arguments.contains("--show-menu")
    private var menuPopupScheduled = false
    var statusItem: NSStatusItem!
    let statusAutosaveName = "BluettiBar.Status"
    lazy var brandBadge: NSImage? = {
        guard let url = Bundle.main.url(forResource: "bluetti-icon", withExtension: "jpg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        return image
    }()
    var pollTimer: Timer?
    var ageTimer: Timer?
    var job: CLIJob?
    var generation = 0
    var pendingRefresh = false
    let maximumReadRetries = 3
    var consecutiveReadFailures = 0
    var nextReadRetryAt: Date?
    var pendingScan = false
    var isScanning = false
    var scanError: String?
    lazy var stationDirectory: BlueBarStationDirectory = {
        return self.demo ? BlueBarStationDirectory(defaults: nil) : BlueBarStationDirectory()
    }()
    lazy var readingStore = BlueBarReadingStore(defaults: self.demo ? nil : self.defaults,
                                                       fallbackStatusURL: self.demo ? nil : self.cacheURL)
    let stationMenu = NSMenu(title: "Station")
    let stationItem = NSMenuItem()
    var stationMenuIsOpen = false
    var stationMenuNeedsRebuild = false
    let renameItem = NSMenuItem(title: "Rename station…", action: nil, keyEquivalent: "")
    var sleeping = false
    var quitting = false
    var awaitingFirstRead = true
    var lastGood: Reading?
    var lastGoodSnapshot: [String: Any]?
    var lastError: String? = "Connecting…"
    var hasConnectionFailure = false
    var runtimeFrozenAt: Date?
    var loadHistory = LoadChartHistory()
    let loadGraph = LoadGraphView()
    let loadGraphItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let loadGraphSeparator = NSMenuItem.separator()

    let menu = NSMenu()
    let fixedMenuFont = NSFont.systemFont(ofSize: 12)
    var lastReadTimer: Timer?
    var mainMenuIsOpen = false
    let percentVisibilityItem = NSMenuItem()
    let outputVisibilityItem = NSMenuItem()
    var visibility: StatusVisibility {
        get {
            StatusVisibility(showOutput: !defaults.bool(forKey: "hideOutputWatts"),
                             showPercentage: !defaults.bool(forKey: "hideBatteryPercent"))
        }
        set {
            defaults.set(!newValue.showOutput, forKey: "hideOutputWatts")
            defaults.set(!newValue.showPercentage, forKey: "hideBatteryPercent")
        }
    }

    let iconVisibilityItem = NSMenuItem()
    let runtimeItem = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "r")
    let runtimeButton = NSButton(frame: .zero)
    let runtimeRefreshButton = NSButton(frame: .zero)
    let powerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let timeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let fontSlider = NSSlider(frame: .zero)
    let fontSizeValue = NSTextField(labelWithString: "11")
    let textColorButton = NSButton(frame: .zero)
    let refreshSlider = NSSlider(frame: .zero)
    let refreshValue = NSTextField(labelWithString: "Refresh: 30s")

    var refreshInterval: TimeInterval {
        let saved = defaults.integer(forKey: "refreshIntervalSeconds")
        return TimeInterval(refreshChoices.contains { $0.0 == saved } ? saved : 30)
    }

    var maximumAge: TimeInterval { return max(90, refreshInterval + 35) }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss d/M/yy"
        return formatter
    }()

    func shortDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    var statusFontSize: CGFloat {
        let saved = defaults.integer(forKey: "statusFontSize")
        return CGFloat((9...18).contains(saved) ? saved : 11)
    }

    var customStatusTextColor: NSColor? {
        guard let rgb = defaults.array(forKey: "statusTextColorRGB") as? [Double],
              rgb.count == 3, rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            return nil
        }
        return NSColor(srgbRed: CGFloat(rgb[0]), green: CGFloat(rgb[1]),
                       blue: CGFloat(rgb[2]), alpha: 1)
    }

    var statusTextColor: NSColor { return customStatusTextColor ?? .labelColor }

    var showBrandIcon: Bool {
        return defaults.object(forKey: "showBrandIcon") == nil || defaults.bool(forKey: "showBrandIcon")
    }

    var isLoadingReading: Bool {
        return !sleeping && !quitting
            && (awaitingFirstRead || pendingRefresh || (job != nil && !isScanning))
    }

    var identifier: String {
        return defaults.string(forKey: "stationIdentifier") ?? ""
    }

    var cacheURL: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/BlueBar", isDirectory: true)
        return directory.appendingPathComponent(demo ? "demo-status.json" : "status.json")
    }

    var helperURL: URL {
        return Bundle.main.executableURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BluettiBar")
    }

    private func buildMenu() {
        let positionKey = "NSStatusItem Preferred Position " + statusAutosaveName
        if defaults.object(forKey: positionKey) == nil { defaults.set(0, forKey: positionKey) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = statusAutosaveName
        statusItem.behavior = []
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.setAccessibilityIdentifier(statusAutosaveName)
            button.font = NSFont.monospacedDigitSystemFont(ofSize: statusFontSize, weight: .regular)
            button.image = nil
            button.imagePosition = .noImage
        }
        // Read the separate per-station store before status.json is replaced by
        // a pending/error response. A restored sample never becomes fresh API data.
        restoreSelectedReading()
        makeMenu()
        statusItem.menu = menu
        menu.delegate = self
        render()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        if statusItem.isVisible && statusItem.button != nil && statusItem.menu === menu {
            BluettiInstallation.publishReady()
        }
        writeFailure("Waiting for a fresh Bluetooth reading.")

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        restartPollTimer()
        restartAgeTimer()
        refresh()
        if showMenuAfterLaunch { scheduleMenuPopup() }
    }

    // A second `open BluettiBar.app` is delivered to this running instance. The
    // popup stays reachable even when macOS hides its status item under a notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if statusItem == nil { showMenuAfterLaunch = true }
        else { scheduleMenuPopup() }
        return false
    }

    private func scheduleMenuPopup() {
        guard !quitting, !menuPopupScheduled else { return }
        menuPopupScheduled = true
        // Let launch/reopen finish first; never wait for Bluetooth or an ETA.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            self.menuPopupScheduled = false
            guard !self.quitting, self.statusItem != nil else { return }
            self.render()
            NSApp.activate(ignoringOtherApps: true)
            self.menu.cancelTracking()
            _ = self.menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func willSleep(_ notification: Notification) {
        sleeping = true
        generation += 1
        pendingRefresh = false
        pendingScan = false
        job?.cancel(reason: "Mac is sleeping.")
        fail("Mac is sleeping; Bluetooth reading paused.")
        rebuildStationMenu()
    }

    @objc private func didWake(_ notification: Notification) {
        sleeping = false
        generation += 1
        resetReadRetryBudget()
        pendingRefresh = true
        fail("Reconnecting after wake…")
        job?.cancel()
        rebuildStationMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    @objc func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        pollTimer?.invalidate()
        ageTimer?.invalidate()
        guard let running = job else { return .terminateNow }
        running.cancel(reason: "BluettiBar is quitting.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, self.quitting, self.job != nil else { return }
            self.job?.forceStop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        job?.forceStop()
        freezeRuntime()
        saveReadingState()
        writeFailure("BluettiBar is not running.")
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { return true }
}
