import AppKit

extension BlueBarDelegate {
    private func statusSymbol(_ name: String, description: String,
                              color: NSColor, alpha: CGFloat) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description),
              symbol.size.width > 0, symbol.size.height > 0 else { return nil }
        let edge: CGFloat = 6 * statusFontSize / 11
        let scale: CGFloat = edge / max(symbol.size.width, symbol.size.height)
        let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let icon = NSImage(size: size)
        let drawIcon = {
            icon.lockFocus()
            let rect = NSRect(origin: .zero, size: size)
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.withAlphaComponent(alpha).setFill()
            rect.fill(using: .sourceIn)
            icon.unlockFocus()
        }
        if let appearance = statusItem?.button?.effectiveAppearance {
            appearance.performAsCurrentDrawingAppearance(drawIcon)
        } else { drawIcon() }
        // With the default color, let the menu bar resolve its own appearance.
        // Explicit RGB colors keep their pre-tinted pixels.
        icon.isTemplate = customStatusTextColor == nil
        return icon
    }

    private func statusBarImage(color: NSColor, hasReading: Bool, loading: Bool, offline: Bool) -> NSImage? {
        let indicator: NSImage?
        if hasReading && loading {
            indicator = statusSymbol("arrow.clockwise", description: "Reading station",
                                     color: color, alpha: 0.65)
        } else if hasReading && offline {
            indicator = statusSymbol("wifi.slash", description: "Offline",
                                     color: color, alpha: 0.45)
        } else { indicator = nil }
        // With no known percentage, keep just the brand as the menu's handle,
        // even when the user normally hides it beside a known percentage.
        guard showBrandIcon || !hasReading, let badge = brandBadge else { return indicator }
        let scale = statusFontSize / 11
        let side: CGFloat = (hasReading ? 7 * scale : min(22, 18 * scale)).rounded()
        let gap: CGFloat = indicator == nil ? 0 : scale
        let size = NSSize(width: side + gap + (indicator?.size.width ?? 0), height: side)
        let image = NSImage(size: size)
        image.lockFocus()
        badge.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: .zero, operation: .sourceOver, fraction: 1)
        if let indicator = indicator {
            // The indicator was already tinted in the status button's current
            // appearance. The brand's blue and white pixels stay unchanged.
            indicator.isTemplate = false
            indicator.draw(in: NSRect(x: side + gap, y: (side - indicator.size.height) / 2,
                                      width: indicator.size.width, height: indicator.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1)
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func updateLastRead(now: Date) {
        lastReadTimer?.invalidate()
        lastReadTimer = nil
        timeItem.isHidden = lastGood == nil
        guard let date = lastGood?.measuredAt else { return }
        let age = MenuPresentation.lastRead(date, now: now)
        timeItem.title = age.title
        timeItem.toolTip = shortDate(date)
        guard mainMenuIsOpen else { return }
        let timer = Timer(fire: age.nextUpdate, interval: 0, repeats: false) { [weak self] _ in
            self?.updateLastRead(now: Date())
        }
        lastReadTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func render() {
        guard statusItem != nil else { return }
        if !uiSelfTest && !quitting && !statusItem.isVisible { statusItem.isVisible = true }
        let reading = lastGood
        let now = Date()
        let stale = reading.map { now.timeIntervalSince($0.measuredAt) > maximumAge } ?? false
        let offline = sleeping || hasConnectionFailure || stale
        if offline || reading?.runtimeCarriedForward == true { freezeRuntime() }
        let runtime = MenuPresentation.runtime(for: reading, now: now, maximumAge: maximumAge,
                                               frozenAt: runtimeFrozenAt, loading: isLoadingReading,
                                               error: lastError, shortDate: shortDate)
        runtimeItem.title = runtime.title
        let visibility = self.visibility
        let title = reading.map { visibility.title(for: $0) } ?? ""
        let font = NSFont.monospacedDigitSystemFont(ofSize: statusFontSize, weight: .regular)
        let color = statusTextColor
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let custom = customStatusTextColor { attributes[.foregroundColor] = custom }
        let styledTitle = NSAttributedString(string: title, attributes: attributes)
        statusItem.button?.title = title
        statusItem.button?.font = font
        statusItem.button?.attributedTitle = styledTitle
        let showInitialLoading = awaitingFirstRead && isLoadingReading
        let image = statusBarImage(color: color, hasReading: reading != nil,
                                   loading: showInitialLoading, offline: offline)
        statusItem.button?.image = image
        statusItem.button?.imagePosition = image == nil ? .noImage : .imageLeft
        statusItem.button?.imageScaling = .scaleNone
        statusItem.button?.setAccessibilityLabel((demo ? "DEMO, " : "") + "BLUETTI, " + title
            + (showInitialLoading ? ", reading station" : (offline ? ", offline" : "")))
        let power = MenuPresentation.power(for: reading, shortDate: shortDate)
        powerItem.title = power.title
        powerItem.toolTip = power.toolTip
        powerItem.isHidden = power.title.isEmpty
        if mainMenuIsOpen { loadGraph.update(points: loadHistory.visiblePoints(at: now), now: now) }
        loadGraphItem.isHidden = reading == nil
        loadGraphSeparator.isHidden = reading == nil
        stationItem.title = stationDisplayName
        stationItem.toolTip = reading?.device ?? selectedKnownStation?.bluetoothName
        stationItem.isEnabled = !demo && !quitting
        renameItem.isEnabled = selectedKnownStation != nil && !quitting
        updateLastRead(now: now)
        let detail = lastError ?? (stale ? "Waiting for a fresh Bluetooth reading." : "")
        let lastRead = reading.map { "last read: " + shortDate($0.measuredAt) }
        statusItem.button?.toolTip = (demo ? "DEMO\n" : "") + stationDisplayName
            + (lastRead.map { "\n" + $0 } ?? "")
            + (detail.isEmpty ? "" : "\n" + detail)
        runtimeButton.title = (demo ? "DEMO · " : "") + runtimeItem.title
        for (button, visible, name) in [
            (iconVisibilityButton, showBrandIcon, "icon"),
            (percentVisibilityButton, visibility.showsPercentage(for: reading), "percentage"),
            (outputVisibilityButton, visibility.showOutput, "output power")
        ] {
            button.image = NSImage(systemSymbolName: visible ? "eye" : "eye.slash", accessibilityDescription: nil)
            let action = (visible ? "Hide " : "Show ") + name
            button.toolTip = action
            button.setAccessibilityLabel(action)
        }
        percentVisibilityButton.isEnabled = visibility.canHidePercentage(for: reading)
        let runtimeTip = (runtime.toolTip.map { $0 + "\n" } ?? "") + "Click to refresh."
        runtimeButton.toolTip = runtimeTip
        runtimeItem.toolTip = runtimeTip
        let canRefresh = job == nil && !sleeping && !quitting
        runtimeButton.isEnabled = canRefresh
        runtimeRefreshButton.isEnabled = canRefresh
    }
}
