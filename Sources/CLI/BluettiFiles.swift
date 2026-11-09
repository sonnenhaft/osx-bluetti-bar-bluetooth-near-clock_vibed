// Runs in the app executable's isolated --bluetti-helper process, before NSApp.
// Foundation/POSIX only; the same code can be exercised without Bluetooth.
import Foundation
import CoreFoundation
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum BluettiFiles {
    static func cacheDirectory() throws -> URL {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
            throw BluettiCommandError("filesystem", "Cannot determine the user's home directory.")
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Caches/BlueBar", isDirectory: true)
    }

    static func unixNow() throws -> UInt64 {
        let seconds = Date().timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64.max) else {
            throw BluettiCommandError("clock", "The system clock is earlier than the Unix epoch or is invalid.")
        }
        return UInt64(seconds)
    }

    static func systemError(_ number: Int32 = errno) -> String { return String(cString: strerror(number)) }

    static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                #if canImport(Darwin)
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                #else
                let written = Glibc.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                #endif
                if written < 0 {
                    if errno == EINTR { continue }
                    throw BluettiCommandError("output", systemError())
                }
                guard written > 0 else { throw BluettiCommandError("output", "Could not write output.") }
                offset += written
            }
        }
    }

    static func atomicWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".runtime-history-\(getpid())-\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600)) }
        guard descriptor >= 0 else { throw BluettiCommandError("filesystem", "Cannot create runtime history: \(systemError())") }
        var openDescriptor = true
        var renamed = false
        defer {
            if openDescriptor { _ = close(descriptor) }
            if !renamed { _ = temporary.path.withCString { unlink($0) } }
        }
        // create(...,0600) never temporarily exposes a newly written history.
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw BluettiCommandError("filesystem", "Cannot protect runtime history: \(systemError())")
        }
        try writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else { throw BluettiCommandError("filesystem", "Cannot sync runtime history: \(systemError())") }
        let closeResult = close(descriptor)
        openDescriptor = false
        guard closeResult == 0 else { throw BluettiCommandError("filesystem", "Cannot close runtime history: \(systemError())") }
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in rename(source, target) }
        }
        guard result == 0 else { throw BluettiCommandError("filesystem", "Cannot replace runtime history: \(systemError())") }
        renamed = true
    }

    static func validateStatus(_ status: BluettiStatus, now: UInt64) throws {
        guard status.ok, status.model == "AC50P", !status.device.isEmpty, status.batteryPercent <= 100 else {
            throw BluettiCommandError("invalid_data", "Battery data is missing or invalid; no percentage will be shown.")
        }
        let futureLimit = now > UInt64.max - 5 ? UInt64.max : now + 5
        guard status.observedAt <= futureLimit else {
            throw BluettiCommandError("invalid_data", "Cached timestamp is in the future. Check the Mac clock.")
        }
        let maximumAge: UInt64
        if let interval = status.refreshIntervalSeconds {
            guard let seconds = Int(exactly: interval), PollInterval(rawValue: seconds) != nil else {
                throw BluettiCommandError("invalid_data", "Invalid cached refresh interval; expected 1, 3, 5, 20, 30, 60 or 120 seconds.")
            }
            maximumAge = max(90, interval + 35)
        } else { maximumAge = 90 }
        if let runtime = status.runtime, !runtime.isValid(percent: status.batteryPercent) {
            throw BluettiCommandError("invalid_data", "Cached runtime is invalid or exceeds seven days.")
        }
        let age = now >= status.observedAt ? now - status.observedAt : 0
        guard age <= maximumAge else {
            throw BluettiCommandError("stale", "Cached reading is \(age)s old (maximum \(maximumAge)s). Open BluettiBar to refresh the cache, or use bluetti status for a fresh reading.")
        }
    }

    static func cachedStatus(directory: URL, device: String?, now: UInt64) throws -> BluettiStatus {
        let bytes: Data
        do { bytes = try Data(contentsOf: directory.appendingPathComponent("status.json")) }
        catch {
            throw BluettiCommandError("cache", "No readable BluettiBar cache: \(error.localizedDescription). Open BluettiBar to refresh the cache, or use bluetti status for a fresh reading.")
        }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: bytes) }
        catch { throw BluettiCommandError("cache", "Invalid cache JSON: \(error.localizedDescription)") }
        if let object = value as? [String: Any], let ok = object["ok"] as? NSNumber,
           CFGetTypeID(ok) == CFBooleanGetTypeID(), !ok.boolValue {
            throw BluettiCommandError("cache", object["error"] as? String ?? "The last BluettiBar Bluetooth reading failed.")
        }
        let status: BluettiStatus
        do { status = try JSONDecoder().decode(BluettiStatus.self, from: bytes) }
        catch { throw BluettiCommandError("cache", "Invalid cache JSON: \(error.localizedDescription)") }
        try validateStatus(status, now: now)
        if let selector = device {
            let matches = status.device.lowercased().contains(selector.lowercased())
                || status.deviceID?.caseInsensitiveCompare(selector) == .orderedSame
            guard matches else { throw BluettiCommandError("cache", "The cached reading belongs to a different station.") }
        }
        return status
    }
}

// A genuine nonblocking cross-process flock. Never unlink this file: replacing
// its inode could allow two processes to hold independent "exclusive" locks.
