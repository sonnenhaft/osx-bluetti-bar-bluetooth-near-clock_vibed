import AppKit

extension BlueBarDelegate {
    var selectedKnownStation: BlueBarKnownStation? {
        if !identifier.isEmpty {
            let stations = stationDirectory.stations
            if let exact = stations.first(where: {
                $0.deviceID?.caseInsensitiveCompare(identifier) == .orderedSame
            }) { return exact }
            let name = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping.lowercased()
            let matches = stations.filter { $0.seenNames.contains(name) }
            return matches.count == 1 ? matches[0] : nil
        }
        guard let sample = lastGood else { return nil }
        return stationDirectory.station(deviceID: sample.deviceID, bluetoothName: sample.device)
    }

    var stationDisplayName: String {
        if let sample = lastGood {
            return stationDirectory.displayName(deviceID: sample.deviceID, bluetoothName: sample.device)
        }
        return selectedKnownStation?.displayName ?? (identifier.isEmpty ? "Automatic" : identifier)
    }

    func addStationControl() {
        stationMenu.autoenablesItems = false
        stationMenu.font = fixedMenuFont
        stationMenu.delegate = self
        stationItem.submenu = stationMenu
        menu.addItem(stationItem)
        renameItem.target = self
        renameItem.action = #selector(renameStation)
        rebuildStationMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === stationMenu { stationMenuIsOpen = true; return }
        mainMenuIsOpen = true
        render()
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu {
            mainMenuIsOpen = false
            lastReadTimer?.invalidate()
            lastReadTimer = nil
        }
        if menu === stationMenu {
            stationMenuIsOpen = false
            if stationMenuNeedsRebuild { rebuildStationMenu() }
        }
    }

    func rebuildStationMenu() {
        guard !stationMenuIsOpen else { stationMenuNeedsRebuild = true; return }
        stationMenuNeedsRebuild = false
        stationMenu.removeAllItems()
        let automatic = NSMenuItem(title: "Automatic", action: #selector(selectStation(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.representedObject = ""
        automatic.state = identifier.isEmpty ? .on : .off
        stationMenu.addItem(automatic)
        for station in stationDirectory.stations {
            let item = NSMenuItem(title: station.displayName + " (" + station.model + ")",
                                 action: #selector(selectStation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = station.selector
            item.toolTip = station.bluetoothName
            item.state = identifier.caseInsensitiveCompare(station.selector) == .orderedSame
                || identifier.caseInsensitiveCompare(station.bluetoothName) == .orderedSame ? .on : .off
            stationMenu.addItem(item)
        }
        stationMenu.addItem(.separator())
        let title = pendingScan || isScanning ? "Scanning…" : (scanError == nil ? "Scan for stations" : "Retry scan")
        let scan = NSMenuItem(title: title, action: #selector(requestStationScan), keyEquivalent: "")
        scan.target = self
        scan.toolTip = scanError
        scan.isEnabled = !demo && !pendingScan && !isScanning && !sleeping && !quitting
        stationMenu.addItem(scan)
        stationMenu.addItem(renameItem)
        stationItem.title = stationDisplayName
    }

    @objc func requestStationScan() {
        guard !demo, !sleeping, !quitting, !pendingScan, !isScanning else { return }
        pendingScan = true
        scanError = nil
        rebuildStationMenu()
        runQueuedWork()
    }

    func startStationScan() {
        guard !demo, !sleeping, !quitting, job == nil else { return }
        pendingScan = false
        isScanning = true
        let read = CLIJob()
        let thisGeneration = generation
        job = read
        rebuildStationMenu()
        render()
        read.run(executable: helperURL, arguments: ["scan", "--timeout", "12"]) { [weak self, weak read] result in
            DispatchQueue.main.async {
                guard let self = self, let read = read, self.job === read else { return }
                self.job = nil
                self.isScanning = false
                if self.quitting {
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                if thisGeneration == self.generation, !self.sleeping {
                    let object = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any]
                    if result.error == nil, result.exitCode == 0,
                       let object = object, object["ok"] as? Bool == true,
                       object["devices"] is [[String: Any]] {
                        self.stationDirectory.ingestScan(object)
                        self.scanError = nil
                    } else {
                        let stderr = String(data: result.stderr, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        self.scanError = result.error ?? (object?["error"] as? String)
                            ?? (stderr?.isEmpty == false ? stderr : nil)
                            ?? "Station scan failed."
                    }
                }
                self.rebuildStationMenu()
                self.render()
                self.runQueuedWork(refreshAfterScan: true)
            }
        }
    }

    @objc func selectStation(_ sender: NSMenuItem) {
        guard !demo, !quitting, let value = sender.representedObject as? String, value != identifier else { return }
        // Save the previous station before changing the selector. Its values
        // never remain on-screen while the next station is connecting.
        freezeRuntime()
        saveReadingState()
        defaults.set(value, forKey: "stationIdentifier")
        generation += 1
        resetReadRetryBudget()
        awaitingFirstRead = true
        restoreSelectedReading()
        loadHistory.clear()
        pendingScan = false
        scanError = nil
        pendingRefresh = true
        lastError = "Waiting for a reading from the selected station."
        hasConnectionFailure = false
        writeFailure(lastError!)
        rebuildStationMenu()
        render()
        if let running = job { running.cancel() }
        else { runQueuedWork() }
    }

    @objc func renameStation() {
        guard !quitting, let station = selectedKnownStation else { return }
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.quitting else { return }
            let alias = BlueBarAliasEditor.edit(alias: station.alias ?? "",
                                                placeholder: station.bluetoothName)
            guard !self.quitting, let alias = alias else { return }
            self.stationDirectory.setAlias(alias, deviceID: station.deviceID,
                                           bluetoothName: station.bluetoothName, model: station.model)
            self.rebuildStationMenu()
            self.render()
        }
    }
}
