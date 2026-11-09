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

    func run(executable: URL, arguments: [String], completion: @escaping (CLIResult) -> Void) {
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

            let drains = DispatchGroup()
            drains.enter()
            DispatchQueue.global(qos: .utility).async {
                outCapture.drain(outPipe.fileHandleForReading)
                drains.leave()
            }
            drains.enter()
            DispatchQueue.global(qos: .utility).async {
                errCapture.drain(errPipe.fileHandleForReading)
                drains.leave()
            }

            let deadline = DispatchWorkItem { [weak self] in
                self?.cancel(reason: "Bluetooth read timed out. Check the station and close the BLUETTI phone app.")
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 36, execute: deadline)
            task.waitUntilExit()
            deadline.cancel()
            drains.wait()

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
