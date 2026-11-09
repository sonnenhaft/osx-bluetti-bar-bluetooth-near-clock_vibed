import Foundation
import Darwin

struct CLIResult {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
    var error: String?
}

// Read both pipes concurrently so a child cannot deadlock on a full stderr pipe.
private final class PipeCapture {
    private let lock = NSLock()
    private var bytes = Data()

    func drain(_ handle: FileHandle) {
        var collected = Data()
        while true {
            let chunk = handle.readData(ofLength: 8192)
            if chunk.isEmpty { break }
            // Keep bounded diagnostics, but always drain the remainder of the pipe.
            if collected.count < 262_144 {
                collected.append(chunk.prefix(262_144 - collected.count))
            }
        }
        lock.lock()
        bytes = collected
        lock.unlock()
        try? handle.close()
    }

    // The session writes one JSON object per line. Retain only its final
    // error for the exit handler; successful samples go straight to the UI.
    func drainSamples(_ handle: FileHandle, receive: ([String: Any]) -> Void, invalid: () -> Void) {
        defer { try? handle.close() }
        var pending = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let end = pending.firstIndex(of: 0x0a) {
                let line = Data(pending[..<end])
                pending.removeSubrange(...end)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    invalid()
                    return
                }
                if object["ok"] as? Bool == true { receive(object) }
                else {
                    lock.lock()
                    bytes = line
                    lock.unlock()
                }
            }
            if pending.count > 262_144 { invalid(); return }
        }
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}

final class CLIJob {
    private let lock = NSLock()
    private var process: Process?
    private var stopReason: String?
    private var finished = false

    func run(executable: URL, arguments: [String],
             onSample: (([String: Any]) -> Void)? = nil, completion: @escaping (CLIResult) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.executableURL = executable
            task.arguments = ["--bluetti-helper"] + arguments
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = outPipe
            task.standardError = errPipe
            let outCapture = PipeCapture()
            let errCapture = PipeCapture()

            self.lock.lock()
            if let reason = self.stopReason {
                self.finished = true
                self.lock.unlock()
                completion(CLIResult(exitCode: -1, stdout: Data(), stderr: Data(), error: reason))
                return
            }
            self.process = task
            do {
                try task.run()
            } catch {
                self.finished = true
                self.process = nil
                self.lock.unlock()
                completion(CLIResult(exitCode: -1, stdout: Data(), stderr: Data(),
                                     error: "Cannot launch Bluetooth reader: \(error.localizedDescription)"))
                return
            }
            self.lock.unlock()

            // Allow 1.5 seconds for SIGTERM cleanup before forceStop.
            let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            watchdog.setEventHandler { [weak self] in
                self?.cancel(reason: "Bluetooth operation timed out.")
            }
            watchdog.schedule(deadline: .now() + 13.5)
            watchdog.resume()
            let drains = DispatchGroup()
            drains.enter()
            DispatchQueue.global(qos: .utility).async {
                if let onSample = onSample {
                    outCapture.drainSamples(outPipe.fileHandleForReading, receive: { sample in
                        watchdog.schedule(deadline: .now() + 13.5)
                        onSample(sample)
                    }, invalid: { self.cancel(reason: "Invalid Bluetooth sample stream.") })
                } else {
                    outCapture.drain(outPipe.fileHandleForReading)
                }
                drains.leave()
            }
            drains.enter()
            DispatchQueue.global(qos: .utility).async {
                errCapture.drain(errPipe.fileHandleForReading)
                drains.leave()
            }

            task.waitUntilExit()
            drains.wait()
            watchdog.cancel()

            self.lock.lock()
            self.finished = true
            let reason = self.stopReason
            self.process = nil
            self.lock.unlock()
            completion(CLIResult(exitCode: task.terminationStatus,
                                 stdout: outCapture.data(), stderr: errCapture.data(), error: reason))
        }
    }

    func cancel(reason: String = "Bluetooth read cancelled.") {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if stopReason == nil { stopReason = reason }
        let running = process
        lock.unlock()
        guard let task = running, task.isRunning else { return }
        task.terminate()
        // A process stuck in the Bluetooth stack still must not survive the app.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.forceStop()
        }
    }

    func forceStop() {
        lock.lock()
        defer { lock.unlock() }
        if !finished, let task = process, task.isRunning {
            _ = Darwin.kill(task.processIdentifier, SIGKILL)
        }
    }
}
