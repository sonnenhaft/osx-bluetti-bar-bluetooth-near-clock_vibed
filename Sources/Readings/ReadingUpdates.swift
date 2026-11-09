import AppKit
import CoreFoundation

extension BlueBarDelegate {
    @discardableResult
    func accept(_ snapshot: [String: Any], restoring: Bool = false) -> Bool {
        var reading: Reading
        do {
            reading = try Reading.decode(snapshot, previous: restoring ? nil : lastGood, now: Date(),
                                         maximumAge: restoring ? nil : maximumAge)
        } catch {
            if !restoring { readFailed(error.localizedDescription) }
            return false
        }
        if !restoring, let previous = lastGood,
           !previous.matchesStation(id: reading.deviceID, name: reading.device) {
            loadHistory.clear()
        }
        if reading.runtimeCarriedForward { freezeRuntime() }
        else { runtimeFrozenAt = nil }
        if restoring {
            let frozen = restoreDisplayMetadata(snapshot["_bluebar_display"], into: &reading)
            // Offline elapsed time is not a new measurement. Freeze the saved
            // estimate at its saved display moment, or at its observation.
            runtimeFrozenAt = frozen ?? reading.runtimeMeasuredAt
        }
        lastGood = reading
        lastGoodSnapshot = snapshot
        stationDirectory.ingestStatus(snapshot)
        if restoring {
            loadHistory.markGap()
            lastError = "Waiting for a fresh Bluetooth reading."
            hasConnectionFailure = false
            return true
        }
        // Older versions allowed a partial CLI selector. Once a real reading
        // identifies it, persist the exact target so restart can restore it.
        if !demo && !identifier.isEmpty {
            defaults.set(reading.deviceID ?? reading.device, forKey: "stationIdentifier")
        }
        if consecutiveReadFailures > 0 {
            consecutiveReadFailures = 0
            restartPollTimer()
        }
        nextReadRetryAt = nil
        awaitingFirstRead = false
        rebuildStationMenu()
        loadHistory.append(timestamp: reading.measuredAt, watts: reading.outputWatts, maximumGap: maximumAge)
        lastError = nil
        restartAgeTimer()
        hasConnectionFailure = false
        saveReadingState()
        // Keep the actual helper payload in the API cache. Retained display
        // fields are never relabelled with the new sample's timestamp.
        writeCache(snapshot)
        render()
        return true
    }

    func restoreSelectedReading() {
        lastGood = nil
        lastGoodSnapshot = nil
        runtimeFrozenAt = nil
        guard !demo,
              let snapshot = readingStore.reading(for: identifier, knownStations: stationDirectory.stations) else { return }
        accept(snapshot, restoring: true)
    }

    private func restoreDisplayMetadata(_ value: Any?, into reading: inout Reading) -> Date? {
        guard let display = value as? [String: Any] else { return nil }
        func number(_ value: Any?) -> Double? {
            guard let raw = value as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID(),
                  raw.doubleValue.isFinite else { return nil }
            return raw.doubleValue
        }
        func date(_ key: String) -> Date? {
            return number(display[key]).map { Date(timeIntervalSince1970: $0) }
        }
        guard number(display["version"]) == 1 else { return nil }
        for key in ["ac_input_w", "dc_input_w", "ac_output_w", "dc_output_w"] {
            if let raw = display[key] {
                guard let watts = number(raw), watts >= 0 else { return nil }
            }
        }
        if let raw = display["runtime_battery_percent"], number(raw) == nil { return nil }
        let percent = number(display["runtime_battery_percent"]) ?? Double(reading.percent)
        guard percent.rounded() == percent, (0...100).contains(percent),
              let runtime = RuntimeEstimate.parse(display["runtime"], percent: Int(percent)),
              let observed = number(display["runtime_observed_at"]), observed >= 0,
              observed <= reading.measuredAt.timeIntervalSince1970 + 30,
              observed <= Date().timeIntervalSince1970 + 30 else { return nil }
        for key in ["input_retained_at", "output_retained_at", "runtime_frozen_at"] {
            if let raw = display[key] {
                guard let seconds = number(raw), seconds >= 0,
                      seconds <= Date().timeIntervalSince1970 + 30,
                      (key == "runtime_frozen_at" ? seconds >= observed
                       : seconds <= reading.measuredAt.timeIntervalSince1970 + 30) else { return nil }
            }
        }
        var carried = false
        if let raw = display["runtime_carried_forward"] {
            guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
            carried = flag.boolValue
        }
        // A current valid raw value, especially zero, wins over retained data.
        reading.acInput = reading.acInput ?? number(display["ac_input_w"])
        reading.dcInput = reading.dcInput ?? number(display["dc_input_w"])
        reading.acOutput = reading.acOutput ?? number(display["ac_output_w"])
        reading.dcOutput = reading.dcOutput ?? number(display["dc_output_w"])
        reading.inputPowerRetainedAt = date("input_retained_at")
        reading.outputPowerRetainedAt = date("output_retained_at")
        reading.runtime = runtime
        reading.runtimeMeasuredAt = Date(timeIntervalSince1970: observed)
        reading.runtimePercent = Int(percent)
        reading.runtimeCarriedForward = carried
        return date("runtime_frozen_at")
    }

    func saveReadingState() {
        guard let reading = lastGood, var snapshot = lastGoodSnapshot else { return }
        var display: [String: Any] = [
            "version": 1,
            "runtime": reading.runtime.json,
            "runtime_observed_at": reading.runtimeMeasuredAt.timeIntervalSince1970,
            "runtime_battery_percent": reading.runtimePercent,
            "runtime_carried_forward": reading.runtimeCarriedForward
        ]
        if let watts = reading.acInput { display["ac_input_w"] = watts }
        if let watts = reading.dcInput { display["dc_input_w"] = watts }
        if let watts = reading.acOutput { display["ac_output_w"] = watts }
        if let watts = reading.dcOutput { display["dc_output_w"] = watts }
        if let date = reading.inputPowerRetainedAt { display["input_retained_at"] = date.timeIntervalSince1970 }
        if let date = reading.outputPowerRetainedAt { display["output_retained_at"] = date.timeIntervalSince1970 }
        if let date = runtimeFrozenAt { display["runtime_frozen_at"] = date.timeIntervalSince1970 }
        snapshot["_bluebar_display"] = display
        readingStore.save(snapshot, automatic: identifier.isEmpty)
    }

    func freezeRuntime() {
        guard runtimeFrozenAt == nil, let sample = lastGood else { return }
        runtimeFrozenAt = min(Date(), sample.runtimeMeasuredAt.addingTimeInterval(maximumAge))
    }

    func writeFailure(_ error: String) {
        var snapshot: [String: Any] = [
            "ok": false, "model": "AC50P", "error": error,
            "checked_at": Date().timeIntervalSince1970
        ]
        if let reading = lastGood {
            snapshot["last_success_at"] = reading.measuredAt.timeIntervalSince1970
        }
        if demo { snapshot["demo"] = true }
        writeCache(snapshot)
    }

    private func writeCache(_ snapshot: [String: Any]) {
        var cached = snapshot
        cached["refresh_interval_seconds"] = Int(refreshInterval)
        guard var data = try? JSONSerialization.data(withJSONObject: cached, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true, attributes: nil)
            try data.write(to: cacheURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch {
            NSLog("BluettiBar: cannot write status cache: %@", error.localizedDescription)
        }
    }
}
