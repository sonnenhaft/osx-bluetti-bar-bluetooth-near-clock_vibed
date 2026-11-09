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

final class BluettiBluetoothLock {
    private(set) var descriptor: Int32 = -1

    init(directory: URL) throws {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700]) }
        catch { throw BluettiCommandError("filesystem", "Cannot create cache directory: \(error.localizedDescription)") }
        descriptor = directory.appendingPathComponent("bluetooth.lock").path.withCString {
            open($0, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw BluettiCommandError("filesystem", "Cannot open Bluetooth lock: \(BluettiFiles.systemError())") }
        if fchmod(descriptor, mode_t(0o600)) != 0 {
            let reason = BluettiFiles.systemError()
            release()
            throw BluettiCommandError("filesystem", "Cannot protect Bluetooth lock: \(reason)")
        }
        if Self.tryExclusive(descriptor) != 0 {
            let number = errno
            release()
            if number == EWOULDBLOCK || number == EAGAIN {
                throw BluettiCommandError("busy", "Another BluettiBar Bluetooth read is already running. Use bluetti cached or wait for it to finish.")
            }
            throw BluettiCommandError("filesystem", "Cannot lock Bluetooth reader: \(BluettiFiles.systemError(number))")
        }
    }

    static func tryExclusive(_ descriptor: Int32) -> Int32 {
        return bluetti_flock(descriptor, LOCK_EX | LOCK_NB)
    }

    func release() {
        if descriptor >= 0 { _ = close(descriptor); descriptor = -1 }
    }
    deinit { release() }
}
