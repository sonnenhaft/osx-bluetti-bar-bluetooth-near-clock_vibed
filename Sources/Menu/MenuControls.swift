import AppKit

extension BlueBarDelegate {
    func makeMenu() {
        menu.autoenablesItems = false
        menu.font = fixedMenuFont
        addRuntimeControl()
        for item in [powerItem, timeItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addStationControl()
        addRefreshControl()
        addTextControls()
        addVisibilityControls()
        menu.addItem(.separator())
        action("Quit BluettiBar", #selector(quit), key: "q")
        menu.addItem(loadGraphSeparator)
        loadGraphItem.view = loadGraph
        loadGraphItem.isEnabled = false
        // Axes remain visible before the first two real measurements arrive.
        menu.addItem(loadGraphItem)
    }

    @discardableResult
    func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addRuntimeControl() {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        row.autoresizingMask = [.width]
        runtimeButton.frame = NSRect(x: 10, y: 3, width: 198, height: 24)
        runtimeButton.autoresizingMask = [.width]
        runtimeButton.isBordered = false
        runtimeButton.alignment = .left
        runtimeButton.font = fixedMenuFont
        runtimeButton.target = self
        runtimeButton.action = #selector(refreshClicked)
        row.addSubview(runtimeButton)
        runtimeRefreshButton.frame = NSRect(x: 212, y: 3, width: 22, height: 24)
        runtimeRefreshButton.autoresizingMask = [.minXMargin]
        runtimeRefreshButton.isBordered = false
        runtimeRefreshButton.image = NSImage(systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh")?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        runtimeRefreshButton.imagePosition = .imageOnly
        runtimeRefreshButton.imageScaling = .scaleNone
        runtimeRefreshButton.target = self
        runtimeRefreshButton.action = #selector(refreshClicked)
        runtimeRefreshButton.toolTip = "Refresh"
        row.addSubview(runtimeRefreshButton)
        runtimeItem.target = self
        runtimeItem.action = #selector(refreshClicked)
        runtimeItem.view = row
        runtimeItem.isEnabled = true
        menu.addItem(runtimeItem)
    }

    private func addTextControls() {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 34))
        row.autoresizingMask = [.width]
        fontSizeValue.frame = NSRect(x: 6, y: 9, width: 34, height: 16)
        fontSizeValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        fontSizeValue.textColor = .secondaryLabelColor
        fontSizeValue.alignment = .right
        fontSizeValue.toolTip = nil
        row.addSubview(fontSizeValue)
        fontSlider.frame = NSRect(x: 46, y: 6, width: 112, height: 22)
        fontSlider.autoresizingMask = [.width]
        fontSlider.minValue = 9
        fontSlider.maxValue = 18
        fontSlider.isContinuous = true
        fontSlider.controlSize = .small
        fontSlider.target = self
        fontSlider.action = #selector(changeFontSize(_:))
        fontSlider.toolTip = nil
        fontSlider.setAccessibilityLabel("Text size")
        row.addSubview(fontSlider)
        textColorButton.frame = NSRect(x: 166, y: 5, width: 28, height: 24)
        textColorButton.autoresizingMask = [.minXMargin]
        textColorButton.title = ""
        textColorButton.bezelStyle = .rounded
        textColorButton.imagePosition = .imageOnly
        textColorButton.target = self
        textColorButton.action = #selector(chooseTextColor)
        textColorButton.toolTip = "Text color"
        textColorButton.setAccessibilityLabel("Text color")
        row.addSubview(textColorButton)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = row
        item.isEnabled = true
        menu.addItem(item)
        updateTextControls()
    }

    private func updateTextControls() {
        fontSlider.doubleValue = Double(statusFontSize)
        fontSizeValue.stringValue = String(Int(statusFontSize)) + "px"
        let color = statusTextColor
        textColorButton.image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let swatch = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            color.setFill()
            swatch.fill()
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            swatch.lineWidth = 0.5
            swatch.stroke()
            return true
        }
        render()
    }

    @objc func changeFontSize(_ sender: NSSlider) {
        guard sender.doubleValue.isFinite else { return }
        let size = Int(min(18, max(9, sender.doubleValue)).rounded())
        guard size != Int(statusFontSize) else { return }
        defaults.set(size, forKey: "statusFontSize")
        updateTextControls()
    }

    @objc func chooseTextColor() {
        // End menu tracking first so the system color panel receives its events.
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.quitting else { return }
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSColorPanel.shared
            panel.title = "Text color"
            panel.showsAlpha = false
            panel.isContinuous = true
            panel.color = self.statusTextColor
            panel.setTarget(self)
            panel.setAction(#selector(self.changeTextColor(_:)))
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func changeTextColor(_ sender: NSColorPanel) {
        guard let color = sender.color.usingColorSpace(.sRGB) else { return }
        let rgb = [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
        guard rgb.allSatisfy({ $0.isFinite }) else { return }
        defaults.set(rgb.map { min(1, max(0, $0)) }, forKey: "statusTextColorRGB")
        updateTextControls()
    }

    private func addVisibilityControls() {
        let icon = brandBadge?.copy() as? NSImage
        icon?.size = NSSize(width: 18, height: 18)
        iconVisibilityItem.image = icon
        for (item, selector) in [(iconVisibilityItem, #selector(toggleBrandIcon)),
                                 (percentVisibilityItem, #selector(togglePercent)),
                                 (outputVisibilityItem, #selector(toggleOutput))] {
            item.target = self
            item.action = selector
            menu.addItem(item)
        }
    }

    @objc func togglePercent() {
        visibility.togglePercentage(for: lastGood)
        render()
    }

    @objc func toggleOutput() {
        visibility.toggleOutput()
        render()
    }

    @objc func toggleBrandIcon() {
        defaults.set(!showBrandIcon, forKey: "showBrandIcon")
        render()
    }

    private func addRefreshControl() {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 42))
        row.autoresizingMask = [.width]
        refreshValue.frame = NSRect(x: 12, y: 25, width: 180, height: 15)
        refreshValue.autoresizingMask = [.width]
        refreshValue.font = .systemFont(ofSize: 11)
        refreshValue.textColor = .secondaryLabelColor
        row.addSubview(refreshValue)
        refreshSlider.frame = NSRect(x: 10, y: 1, width: 180, height: 24)
        refreshSlider.autoresizingMask = [.width]
        refreshSlider.controlSize = .small
        refreshSlider.minValue = 0
        refreshSlider.maxValue = Double(refreshChoices.count - 1)
        refreshSlider.numberOfTickMarks = refreshChoices.count
        refreshSlider.allowsTickMarkValuesOnly = true
        refreshSlider.isContinuous = true
        refreshSlider.target = self
        refreshSlider.action = #selector(changeRefreshInterval(_:))
        refreshSlider.toolTip = "5s / 20s / 30s / 1m / 2m"
        refreshSlider.setAccessibilityLabel("Refresh interval")
        row.addSubview(refreshSlider)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = row
        item.isEnabled = true
        menu.addItem(item)
        updateRefreshControl()
    }

    private func updateRefreshControl() {
        let index = refreshChoices.firstIndex { $0.0 == Int(refreshInterval) } ?? 2
        refreshSlider.doubleValue = Double(index)
        refreshValue.stringValue = "Refresh: " + refreshChoices[index].1
        refreshSlider.setAccessibilityValue(refreshChoices[index].1)
    }

    @objc func changeRefreshInterval(_ sender: NSSlider) {
        guard sender.doubleValue.isFinite else { return }
        let index = Int(min(Double(refreshChoices.count - 1), max(0, sender.doubleValue)).rounded())
        let seconds = refreshChoices[index].0
        guard seconds != Int(refreshInterval) else { updateRefreshControl(); return }
        defaults.set(seconds, forKey: "refreshIntervalSeconds")
        updateRefreshControl()
        if consecutiveReadFailures > 0 {
            nextReadRetryAt = Date().addingTimeInterval(pollDelay)
        }
        restartAgeTimer()
        restartPollTimer()
        refresh()
    }
}
