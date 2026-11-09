import AppKit

extension BlueBarDelegate {
    // Validate the live AppKit object tree, not source text or a parallel test menu.
    // The same gate also identifies what the newly launched GUI really built.
    func verifiedMenuFeatures() throws -> [String] {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "BluettiBar.UI", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func visibleRow(containing control: NSView, named name: String) throws -> NSView {
            for item in menu.items {
                guard let row = item.view, control === row || control.isDescendant(of: row) else { continue }
                try require(item.menu === menu && !item.isHidden && item.isEnabled,
                            name + " is not in an enabled, visible main-menu row.")
                var current: NSView? = control
                while let view = current {
                    try require(!view.isHidden, name + " has a hidden view.")
                    if view === row { break }
                    current = view.superview
                }
                let frame = row.convert(control.bounds, from: control)
                try require(frame.width > 0 && frame.height > 0 && row.bounds.contains(frame),
                            name + " is outside its menu row.")
                return row
            }
            throw NSError(domain: "BluettiBar.UI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: name + " is detached from the main menu."])
        }
        func validImage(_ image: NSImage?) -> Bool {
            guard let image = image else { return false }
            return image.isValid && image.size.width > 0 && image.size.height > 0
        }
        try require(statusItem != nil && statusItem.button != nil && statusItem.menu === menu,
                    "The status button is not attached to the actual menu.")
        try require(statusItem.autosaveName == statusAutosaveName,
                    "The status item does not have its own saved identity.")
        try require(statusItem.isVisible == !uiSelfTest,
                    "The running status item is hidden, or the UI test is not isolated.")
        try require(menu.font == fixedMenuFont && stationMenu.font == fixedMenuFont,
                    "The fixed menu fonts are missing.")
        let fontRow = try visibleRow(containing: fontSlider, named: "Font slider")
        try require(fontSlider.isEnabled && fontSlider.minValue == 9 && fontSlider.maxValue == 18
                    && fontSlider.target === self && fontSlider.action == #selector(changeFontSize(_:)),
                    "The font slider range or action is invalid.")
        let intervalRow = try visibleRow(containing: refreshSlider, named: "Refresh slider")
        try require(intervalRow !== fontRow && refreshSlider.isEnabled
                    && refreshSlider.minValue == 0 && refreshSlider.maxValue == 4
                    && refreshSlider.numberOfTickMarks == 5 && refreshSlider.allowsTickMarkValuesOnly
                    && refreshSlider.target === self && refreshSlider.action == #selector(changeRefreshInterval(_:)),
                    "The refresh slider range or action is invalid.")
        let colorRow = try visibleRow(containing: textColorButton, named: "Color button")
        try require(colorRow === fontRow && textColorButton.isEnabled && validImage(textColorButton.image)
                    && textColorButton.target === self && textColorButton.action == #selector(chooseTextColor),
                    "The color button is missing from the font row.")
        try require(stationItem.menu === menu && stationItem.submenu === stationMenu
                    && renameItem.menu === stationMenu && renameItem.action == #selector(renameStation)
                    && stationMenu.items.contains(where: { $0.action == #selector(selectStation(_:)) })
                    && stationMenu.items.contains(where: { $0.action == #selector(requestStationScan) }),
                    "The station submenu or rename action is incomplete.")
        _ = try visibleRow(containing: runtimeButton, named: "Runtime refresh")
        try require(menu.items.first === runtimeItem && runtimeButton.font == fixedMenuFont
                    && runtimeButton.target === self && runtimeButton.action == #selector(refreshClicked)
                    && runtimeRefreshButton.superview === runtimeButton.superview
                    && runtimeRefreshButton.target === self && runtimeRefreshButton.action == #selector(refreshClicked)
                    && validImage(runtimeRefreshButton.image) && !runtimeRefreshButton.isHidden,
                    "The first-row refresh controls are incomplete.")
        for (button, action) in [(iconVisibilityButton, #selector(toggleBrandIcon)),
                                 (percentVisibilityButton, #selector(togglePercent)),
                                 (outputVisibilityButton, #selector(toggleOutput))] {
            _ = try visibleRow(containing: button, named: "Visibility control")
            try require(button.target === self && button.action == action && validImage(button.image),
                        "Missing visibility control.")
        }
        try require(validImage(brandBadge) && brandBadge?.tiffRepresentation != nil,
                    "The bundled BLUETTI image cannot be decoded.")
        if showBrandIcon || lastGood == nil {
            try require(validImage(statusItem.button?.image), "The rendered status image is missing.")
        }
        try require(menu.items.last === loadGraphItem && loadGraphItem.view === loadGraph
                    && menu.numberOfItems >= 2 && menu.item(at: menu.numberOfItems - 2) === loadGraphSeparator
                    && loadGraph.frame.width > 0 && loadGraph.frame.height > 0
                    && loadGraphItem.isHidden == (lastGood == nil)
                    && loadGraphSeparator.isHidden == loadGraphItem.isHidden,
                    "The load graph is not in its expected final position.")
        let features = ["font_slider", "interval_slider", "icon_toggle", "color_control",
                        "station_menu", "runtime_refresh", "load_graph", "brand_asset"]
        // This proves that AppKit has enabled the item, not that a crowded menu
        // bar or display notch cannot cover it. Only the normal UI reports it.
        return uiSelfTest ? features : features + ["status_item_visible"]
    }

    static func runUISelfTest() -> Int32 {
        // A private, volatile defaults domain and memory-only station stores keep
        // this pre-installation check independent of the user's preferences/data.
        let suiteName = "com.local.bluebar.ui-test." + UUID().uuidString
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            return 1
        }
        testDefaults.setVolatileDomain(["statusFontSize": 11, "refreshIntervalSeconds": 30,
                                       "stationIdentifier": "",
                                       "statusTextColorRGB": [Double]()], forName: UserDefaults.argumentDomain)
        testDefaults.set(true, forKey: "showBrandIcon")
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        let delegate = BlueBarDelegate(defaults: testDefaults, uiSelfTest: true)
        delegate.buildMenu(restoringReading: false)
        defer {
            if let item = delegate.statusItem { NSStatusBar.system.removeStatusItem(item) }
        }
        do {
            _ = try delegate.verifiedMenuFeatures()
            let now = Date()
            delegate.awaitingFirstRead = false
            delegate.lastError = nil
            delegate.lastGood = Reading(percent: 73, device: "AC50P UI test", deviceID: nil, measuredAt: now,
                acInput: 370, dcInput: 0, acOutput: 120, dcOutput: 15,
                inputPowerRetainedAt: nil, outputPowerRetainedAt: nil,
                runtime: RuntimeEstimate(state: .discharging, source: .station, backup: false,
                                         remainingSeconds: 7200, windowSeconds: nil, dropPercent: nil),
                runtimeMeasuredAt: now, runtimePercent: 73, runtimeCarriedForward: false)
            delegate.render()
            let features = try delegate.verifiedMenuFeatures()
            guard delegate.statusItem.button?.title == "73% 135 W", !delegate.timeItem.isHidden,
                  delegate.statusItem.button?.image?.tiffRepresentation != nil else {
                throw NSError(domain: "BluettiBar.UI", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The actual reading did not render into the status item."])
            }
            func expect(_ title: String) throws {
                guard delegate.statusItem.button?.title == title else {
                    throw NSError(domain: "BluettiBar.UI", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Expected status title " + title])
                }
            }
            delegate.toggleBrandIcon()
            delegate.togglePercent()
            try expect("135 W")
            delegate.lastGood?.acOutput = nil
            delegate.render()
            try expect("73%")
            delegate.lastGood?.acOutput = 0
            delegate.lastGood?.dcOutput = 0
            delegate.render()
            try expect("0 W")
            delegate.toggleOutput()
            delegate.togglePercent()
            try expect("73%")
            delegate.toggleOutput()
            try expect("73% 0 W")
            let data = try JSONSerialization.data(withJSONObject:
                ["ok": true, "ui_self_test": "passed", "features": features.sorted()], options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([0x0a]))
            return 0
        } catch {
            let value: [String: Any] = ["ok": false, "ui_self_test": "failed", "error": error.localizedDescription]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data + Data([0x0a]))
            }
            return 1
        }
    }
}
