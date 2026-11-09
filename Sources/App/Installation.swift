// Installation and UI-instance lifecycle. No Bluetooth or preference mutations.
import AppKit
import Foundation
import Darwin

enum BluettiInstallation {
    private static let bundleID = "com.local.bluebar"
    private static let ownershipMarker = "Contents/Resources/bluebar-owned"
    private static var instanceLock: Int32 = -1
    private static let startedAt = Date()

    private struct PreviousUI: Codable {
        let bundlePath: String
        let arguments: [String]
    }

    private enum Failure: Error, LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }

    private static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/BlueBar", isDirectory: true)
    }

    private static var readyURL: URL { cacheDirectory.appendingPathComponent("ui-ready.json") }

    static func handle(arguments: [String]) -> Int32? {
        guard let mode = arguments.first, mode.hasPrefix("--installer-") else { return nil }
        do {
            switch mode {
            case "--installer-stop-ui":
                guard arguments.count == 1 || arguments.count == 2 else {
                    throw Failure.message("Invalid installer stop arguments.")
                }
                try stopUI(record: arguments.count == 2 ? arguments[1] : nil)
            case "--installer-restore-ui":
                guard arguments.count == 2 else { throw Failure.message("Missing previous UI record.") }
                try restoreUI(record: arguments[1])
            case "--installer-wait-ready":
                guard arguments.count == 4, UUID(uuidString: arguments[3]) != nil else {
                    throw Failure.message("Invalid installer readiness arguments.")
                }
                try waitForReady(appPath: arguments[1], build: arguments[2], token: arguments[3])
            default:
                throw Failure.message("Unknown installer operation.")
            }
            return 0
        } catch {
            report(error.localizedDescription)
            return 1
        }
    }

    // Only the UI holds this lock; CLI and installation modes never do.
    // The descriptor remains open for the lifetime of the UI process.
    static func claimUIInstance() -> Bool {
        if instanceLock >= 0 { return true }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            report("Cannot create UI state directory: \(error.localizedDescription)")
            return false
        }
        let path = cacheDirectory.appendingPathComponent("ui-instance.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { report("Cannot open UI-instance lock."); return false }
        guard bluetti_flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            report("BluettiBar already has a running UI instance, or its UI lock is unavailable.")
            return false
        }
        instanceLock = descriptor
        return true
    }

    static func publishReady() {
        guard instanceLock >= 0, let executable = Bundle.main.executableURL else { return }
        let arguments = Array(CommandLine.arguments.dropFirst())
        let token = installationToken(in: arguments) ?? ""
        let value: [String: Any] = [
            "format": 1,
            "token": token,
            "pid": Int(getpid()),
            "bundle_path": canonical(Bundle.main.bundleURL).path,
            "executable_path": canonical(executable).path,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "started_at": startedAt.timeIntervalSince1970,
            "ready_at": Date().timeIntervalSince1970
        ]
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try data.write(to: readyURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readyURL.path)
        } catch { report("Cannot publish UI readiness: \(error.localizedDescription)") }
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data(("BluettiBar installer: " + message + "\n").utf8))
    }

    private static func installationToken(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--installation-token"),
              arguments.indices.contains(index + 1),
              UUID(uuidString: arguments[index + 1]) != nil else { return nil }
        return arguments[index + 1]
    }

    private static func executable(in bundleURL: URL) throws -> URL {
        let root = canonical(bundleURL)
        guard let bundle = Bundle(url: root), bundle.bundleIdentifier == bundleID,
              let name = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
              ["BlueBar", "BluettiBar"].contains(name),
              let marker = try? String(contentsOf: root.appendingPathComponent(ownershipMarker), encoding: .utf8),
              (marker.hasPrefix("BlueBar-owned") || marker.hasPrefix("BlueBar AC50P battery monitor, version ")) else {
            throw Failure.message("Refusing to control an unrecognized app at \(root.path).")
        }
        let expected = root.appendingPathComponent("Contents/MacOS/" + name)
        guard canonical(expected).path == expected.path,
              FileManager.default.isExecutableFile(atPath: expected.path) else {
            throw Failure.message("The owned app has an unexpected executable at \(root.path).")
        }
        return expected
    }

    // KERN_PROCARGS2 identifies a process role without matching names or killing
    // unrelated processes. A bounded buffer includes argc, executable and argv.
    private static func processArguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let mibCount = UInt32(mib.count)
        var bytes = [UInt8](repeating: 0, count: 1_048_576)
        var size = bytes.count
        let result = bytes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, mibCount, buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0, size >= MemoryLayout<Int32>.size, size <= bytes.count else { return nil }
        var count: Int32 = 0
        withUnsafeMutableBytes(of: &count) { destination in
            bytes.prefix(MemoryLayout<Int32>.size).withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        guard count > 0, count <= 16_384 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        while cursor < size && bytes[cursor] != 0 { cursor += 1 }
        while cursor < size && bytes[cursor] == 0 { cursor += 1 }
        var resultArguments: [String] = []
        for _ in 0..<Int(count) {
            let start = cursor
            while cursor < size && bytes[cursor] != 0 { cursor += 1 }
            guard cursor < size, let argument = String(bytes: bytes[start..<cursor], encoding: .utf8) else { return nil }
            resultArguments.append(argument)
            cursor += 1
        }
        return resultArguments
    }

    private static func isHeadless(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return true }
        if URL(fileURLWithPath: first).lastPathComponent == "bluetti" { return true }
        let options = arguments.dropFirst()
        return options.contains("--bluetti-helper") || options.contains("--preserve-legacy-reading")
            || options.contains(where: { $0.hasPrefix("--installer-") })
    }

    private static func isDeletedLegacyUI(root: URL, actual: URL, arguments: [String]) -> Bool {
        // The previous installer could delete an old bundle while its UI was
        // still running. Only the four historical installation paths qualify.
        let homeApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let parents = [URL(fileURLWithPath: "/Applications"), homeApps]
        for parent in parents {
            for name in ["BlueBar", "BluettiBar"] {
                let knownRoot = canonical(parent.appendingPathComponent(name + ".app"))
                guard canonical(root) == knownRoot else { continue }
                var metadata = stat()
                guard Darwin.lstat(knownRoot.path, &metadata) != 0, errno == ENOENT else { return false }
                let expected = knownRoot.appendingPathComponent("Contents/MacOS/" + name)
                guard canonical(actual) == expected, let first = arguments.first,
                      first.hasPrefix("/"), canonical(URL(fileURLWithPath: first)) == expected else { return false }
                return true
            }
        }
        return false
    }

    private static func ownedUIApplications() throws -> [(NSRunningApplication, PreviousUI)] {
        var result: [(NSRunningApplication, PreviousUI)] = []
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            if application.processIdentifier == getpid() || application.isTerminated { continue }
            guard let arguments = processArguments(pid: application.processIdentifier) else {
                if application.isTerminated { continue }
                throw Failure.message("Cannot identify app process \(application.processIdentifier); nothing will be force-quit.")
            }
            if isHeadless(arguments) { continue }
            guard let root = application.bundleURL, let actual = application.executableURL else {
                throw Failure.message("Cannot identify the path of app process \(application.processIdentifier).")
            }
            if !isDeletedLegacyUI(root: root, actual: actual, arguments: arguments) {
                let expected = try executable(in: root)
                guard canonical(actual) == expected else {
                    throw Failure.message("Refusing to control an unexpected executable: \(actual.path).")
                }
            }
            result.append((application, PreviousUI(bundlePath: canonical(root).path,
                                                  arguments: Array(arguments.dropFirst()))))
        }
        return result
    }

    private static func recordURL(_ path: String) throws -> URL {
        let url = canonical(URL(fileURLWithPath: path))
        guard url.lastPathComponent == "previous-ui.json",
              url.deletingLastPathComponent().lastPathComponent.hasPrefix(".bluettibar-install.") else {
            throw Failure.message("Invalid installation state path.")
        }
        return url
    }

    private static func pumpRunLoop() {
        // NSRunningApplication's changing properties update on run-loop turns.
        if !RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func stopUI(record: String?) throws {
        let initial = try ownedUIApplications()
        if let path = record {
            let url = try recordURL(path)
            try JSONEncoder().encode(initial.map { $0.1 }).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let graceDeadline = ProcessInfo.processInfo.systemUptime + 8
        var requested = Set<pid_t>()
        while true {
            let applications = try ownedUIApplications()
            if applications.isEmpty { return }
            for (application, _) in applications where !requested.contains(application.processIdentifier) {
                requested.insert(application.processIdentifier)
                _ = application.terminate()
            }
            if ProcessInfo.processInfo.systemUptime >= graceDeadline { break }
            pumpRunLoop()
        }
        let forceDeadline = ProcessInfo.processInfo.systemUptime + 2
        requested.removeAll()
        while true {
            let applications = try ownedUIApplications()
            if applications.isEmpty { return }
            for (application, _) in applications where !requested.contains(application.processIdentifier) {
                requested.insert(application.processIdentifier)
                _ = application.forceTerminate()
            }
            if ProcessInfo.processInfo.systemUptime >= forceDeadline {
                let paths = applications.map { $0.1.bundlePath }.joined(separator: ", ")
                throw Failure.message("Previous UI did not exit; installation was stopped: \(paths).")
            }
            pumpRunLoop()
        }
    }

    private static func restoreUI(record: String) throws {
        // A successful old LaunchAgent bootstrap or a surviving old UI takes precedence.
        guard try ownedUIApplications().isEmpty else { return }
        let data = try Data(contentsOf: recordURL(record))
        let previous = try JSONDecoder().decode([PreviousUI].self, from: data)
        guard let first = previous.first else { return }
        let path = try executable(in: URL(fileURLWithPath: first.bundlePath))
        let task = Process()
        task.executableURL = path
        task.arguments = first.arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
    }

    private static func waitForReady(appPath: String, build: String, token: String) throws {
        let root = canonical(URL(fileURLWithPath: appPath, isDirectory: true))
        let expectedExecutable = try executable(in: root)
        guard Bundle(url: root)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String == build else {
            throw Failure.message("Installed app build does not match the requested build.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var lastReason = "The new UI has not reported readiness."
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try? Data(contentsOf: readyURL),
               let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               value["format"] as? Int == 1, value["token"] as? String == token,
               value["build"] as? String == build,
               value["bundle_path"] as? String == root.path,
               value["executable_path"] as? String == expectedExecutable.path,
               let pid = value["pid"] as? Int, pid > 1, pid <= Int(Int32.max),
               let readyAt = value["ready_at"] as? Double, readyAt.isFinite,
               readyAt <= Date().timeIntervalSince1970 + 2,
               let application = NSRunningApplication(processIdentifier: pid_t(pid)),
               !application.isTerminated, application.bundleIdentifier == bundleID,
               let runningBundle = application.bundleURL, canonical(runningBundle) == root,
               let runningExecutable = application.executableURL, canonical(runningExecutable) == expectedExecutable,
               readyAt >= Date().timeIntervalSince1970 - 60,
               let arguments = processArguments(pid: application.processIdentifier), !isHeadless(arguments),
               installationToken(in: Array(arguments.dropFirst())) == token {
                let applications = try ownedUIApplications()
                guard applications.count == 1, applications.first?.0.processIdentifier == pid_t(pid) else {
                    throw Failure.message("More than one UI is running; the update cannot be confirmed.")
                }
                print("Verified BluettiBar UI: build \(build), PID \(pid), \(root.path)")
                return
            }
            if let applications = try? ownedUIApplications(), !applications.isEmpty {
                lastReason = "A UI process exists, but its build, path, token or menu controls did not match."
            }
            pumpRunLoop()
        }
        throw Failure.message(lastReason + " The previous installation will be restored.")
    }
}
