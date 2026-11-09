import AppKit

extension BlueBarDelegate {
    var pollDelay: TimeInterval {
        consecutiveReadFailures > maximumReadRetries ? max(120, refreshInterval) : refreshInterval
    }

    func restartPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard !quitting else { return }
        let timer = Timer(timeInterval: pollDelay, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func restartAgeTimer() {
        ageTimer?.invalidate()
        ageTimer = nil
        guard !quitting, lastError == nil, let sample = lastGood else { return }
        let delay = max(0.01, sample.measuredAt.addingTimeInterval(maximumAge).timeIntervalSinceNow)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.checkAge() }
        RunLoop.main.add(timer, forMode: .common)
        ageTimer = timer
    }

    func resetReadRetryBudget() {
        consecutiveReadFailures = 0
        nextReadRetryAt = nil
        restartPollTimer()
        restartAgeTimer()
    }

    // Only a failed station-read attempt reaches this method. Scan, restore,
    // staleness, sleep and cancelled/obsolete generations do not spend retries.
    func readFailed(_ error: String) {
        pendingRefresh = false
        consecutiveReadFailures += 1
        nextReadRetryAt = Date().addingTimeInterval(pollDelay)
        restartPollTimer()
        fail(error)
    }

    @objc func refreshClicked() {
        guard !sleeping, !quitting else { return }
        resetReadRetryBudget()
        pendingRefresh = true
        refresh()
    }

    func refresh() {
        guard !sleeping, !quitting, job == nil else { return }
        if let retryAt = nextReadRetryAt, Date() < retryAt { return }
        pendingRefresh = false
        if demo {
            let snapshot: [String: Any] = [
                "ok": true, "model": "AC50P", "device": "DEMO — no station connected",
                "battery_percent": 73, "observed_at": Date().timeIntervalSince1970,
                "ac_input_w": 0, "dc_input_w": 0, "ac_output_w": 120, "dc_output_w": 15,
                "runtime": ["state": "discharging", "source": "soc_history", "remaining_seconds": 14_600,
                            "window_seconds": 600, "drop_percent": 3] as [String: Any],
                "demo": true
            ]
            accept(snapshot)
            return
        }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            readFailed("Bluetooth reader is missing. Reinstall BluettiBar to restore the app executable.")
            return
        }
        let read = CLIJob()
        let thisGeneration = generation
        job = read
        var arguments = ["status", "--timeout", "28"]
        if !identifier.isEmpty { arguments += ["--device", identifier] }
        render()
        read.run(executable: helperURL, arguments: arguments) { [weak self, weak read] result in
            DispatchQueue.main.async {
                guard let self = self, let read = read, self.job === read else { return }
                self.job = nil
                if self.quitting {
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                if thisGeneration != self.generation || self.sleeping {
                    self.render()
                } else {
                    self.handle(result)
                }
                self.runQueuedWork()
            }
        }
    }

    func handle(_ result: CLIResult) {
        if let error = result.error { readFailed(error); return }
        let object = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any]
        if result.exitCode != 0 || object?["ok"] as? Bool != true {
            let stderr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (object?["error"] as? String)
                ?? (stderr?.isEmpty == false ? stderr! : "Reader returned no valid status (exit \(result.exitCode)).")
            readFailed(detail)
            return
        }
        guard let snapshot = object else { readFailed("Reader returned invalid JSON."); return }
        accept(snapshot)
    }

    func fail(_ error: String, offline: Bool = true) {
        awaitingFirstRead = false
        lastError = error
        hasConnectionFailure = offline
        freezeRuntime()
        saveReadingState()
        loadHistory.markGap()
        writeFailure(error)
        render()
    }

    private func checkAge() {
        guard !quitting, let reading = lastGood, lastError == nil else { return }
        if Date().timeIntervalSince(reading.measuredAt) >= maximumAge {
            fail("Reading is stale; waiting for a fresh Bluetooth sample.")
        } else { restartAgeTimer() }
    }

    func runQueuedWork(refreshAfterScan: Bool = false) {
        guard !sleeping, !quitting, job == nil else { return }
        if pendingScan { startStationScan() }
        else if pendingRefresh || refreshAfterScan { refresh() }
    }
}
