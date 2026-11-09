// AC50P protocol adapted from rustytti 0.1.1: https://gitlab.com/spock/rustytti
// Upstream notice: THIRD_PARTY_NOTICES.txt. Crypto uses Apple's system libraries.
import Foundation
import CoreBluetooth

final class BluettiCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let serviceID = CBUUID(string: "FF00")
    private static let notifyID = CBUUID(string: "FF01")
    private static let writeID = CBUUID(string: "FF02")
    private var finalDeadline: TimeInterval
    private var deadline: TimeInterval
    private var central: CBCentralManager!
    private var discovered: [String: (CBPeripheral, BluettiNativeDevice)] = [:]
    private var peripheral: CBPeripheral?
    private var service: CBService?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var failure: BluettiNativeFailure?
    private var connectionFinished = false
    private var connectionError: String?
    private var connected = false
    private var closing = false
    private var expectingDisconnect = false
    private var notifyReady = false
    private var awaitingWrite = false
    private var writeFinished = false
    private var writeError: String?
    private var codec = BluettiFrameDecoder(crypto: BluettiIoTCrypto())

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(timeout: TimeInterval, reserveCleanup: Bool) {
        let start = ProcessInfo.processInfo.systemUptime
        finalDeadline = start + timeout
        deadline = start + max(0.1, timeout - (reserveCleanup ? min(2, timeout / 4) : 0))
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func cancel() {
        failure = .failed(code: "cancelled", message: "Bluetooth reading was cancelled.")
        if central.state == .poweredOn { central.stopScan() }
        if let peripheral = peripheral, peripheral.state != .disconnected {
            expectingDisconnect = true
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func close() {
        closing = true
        if central.state == .poweredOn { central.stopScan() }
        if let peripheral = peripheral, peripheral.state != .disconnected {
            expectingDisconnect = true
            central.cancelPeripheralConnection(peripheral)
            let cleanupEnd = min(finalDeadline, now + 2)
            while peripheral.state != .disconnected && now < cleanupEnd { pump(until: cleanupEnd) }
        }
        peripheral?.delegate = nil
        central.delegate = nil
    }

    private func check() throws {
        if let failure = failure { throw failure }
        if now >= deadline { throw BluettiNativeFailure.failed(code: "timeout", message: "Bluetooth operation exceeded its timeout.") }
    }

    private func pump(until limit: TimeInterval) {
        let slice = min(0.25, max(0, limit - now))
        guard slice > 0 else { return }
        if !RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: slice)) {
            Thread.sleep(forTimeInterval: min(0.05, slice))
        }
    }

    private func wait(until limit: TimeInterval, message: String, condition: () -> Bool) throws {
        while true {
            try check()
            if condition() { return }
            guard now < limit else { throw BluettiNativeFailure.failed(code: "timeout", message: message) }
            pump(until: min(deadline, limit))
        }
    }

    func waitForNextRead(at start: TimeInterval, timeout: TimeInterval) throws {
        // Give each poll its own deadline; the handshake belongs to the first poll.
        deadline = max(start, now) + timeout - 2
        finalDeadline = deadline + 2
        while now < start {
            try check()
            pump(until: start)
        }
        try check()
    }

    func scan(duration: TimeInterval) throws -> [BluettiNativeDevice] {
        try wait(until: min(deadline, now + 5), message: "Bluetooth did not become ready.") { self.central.state == .poweredOn }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        defer { central.stopScan() }
        let scanEnd = min(deadline, now + duration)
        while now < scanEnd {
            if let failure = failure { throw failure }
            pump(until: scanEnd)
        }
        if let failure = failure { throw failure }
        return discovered.values.map { $0.1 }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    func connect(_ device: BluettiNativeDevice) throws {
        try check()
        guard let found = discovered[device.id.lowercased()] else {
            throw BluettiNativeFailure.failed(code: "not_found", message: "Selected AC50P is no longer available.")
        }
        let target = found.0
        peripheral = target
        target.delegate = self
        var lastError: Error = BluettiNativeFailure.failed(code: "timeout", message: "Could not connect to AC50P.")
        for _ in 0..<3 {
            try check()
            connectionFinished = false
            connectionError = nil
            connected = false
            expectingDisconnect = false
            central.connect(target, options: nil)
            do {
                try wait(until: min(deadline, now + 5), message: "Timed out connecting to AC50P.") { self.connectionFinished }
                if let problem = connectionError { throw BluettiNativeFailure.failed(code: "bluetooth", message: problem) }
                if connected { break }
            } catch { lastError = error }
            if let failure = failure { throw failure }
            expectingDisconnect = true
            if target.state != .disconnected {
                central.cancelPeripheralConnection(target)
                try wait(until: min(deadline, now + 1), message: "Timed out cancelling the previous connection.") { target.state == .disconnected }
            }
        }
        guard connected else { throw lastError }
        expectingDisconnect = false
        target.discoverServices([Self.serviceID])
        try wait(until: min(deadline, now + 5), message: "AC50P service discovery timed out.") { self.service != nil }
        guard let service = service else { throw BluettiNativeFailure.failed(code: "bluetooth", message: "Missing AC50P service FF00.") }
        target.discoverCharacteristics([Self.notifyID, Self.writeID], for: service)
        try wait(until: min(deadline, now + 5), message: "AC50P characteristic discovery timed out.") {
            self.notifyCharacteristic != nil && self.writeCharacteristic != nil
        }
        guard let notify = notifyCharacteristic else { throw BluettiNativeFailure.failed(code: "bluetooth", message: "Missing AC50P notification characteristic.") }
        guard notify.properties.contains(.notify) || notify.properties.contains(.indicate) else {
            throw BluettiNativeFailure.failed(code: "bluetooth", message: "AC50P characteristic FF01 cannot notify.")
        }
        target.setNotifyValue(true, for: notify)
        try wait(until: min(deadline, now + 5), message: "AC50P notification subscription timed out.") { self.notifyReady }
    }

    private func write(_ bytes: [UInt8], response: Bool) throws {
        try check()
        guard let peripheral = peripheral, let characteristic = writeCharacteristic, connected else {
            throw BluettiNativeFailure.failed(code: "bluetooth", message: "AC50P is not connected.")
        }
        let kind: CBCharacteristicWriteType = response ? .withResponse : .withoutResponse
        guard characteristic.properties.contains(response ? .write : .writeWithoutResponse) else {
            throw BluettiNativeFailure.failed(code: "bluetooth", message: response ? "ATT Write Request is unavailable." : "ATT Write Command is unavailable.")
        }
        let maximum = peripheral.maximumWriteValueLength(for: kind)
        guard maximum > 0 else { throw BluettiNativeFailure.failed(code: "bluetooth", message: "Bluetooth reported an invalid write length.") }
        let end = min(deadline, now + 3)
        var offset = 0
        while offset < bytes.count {
            try check()
            let finish = min(bytes.count, offset + maximum)
            let part = Data(bytes[offset..<finish])
            if response {
                awaitingWrite = true
                writeFinished = false
                writeError = nil
                defer { awaitingWrite = false }
                peripheral.writeValue(part, for: characteristic, type: kind)
                try wait(until: end, message: "Bluetooth Write Request timed out.") { self.writeFinished }
                if let error = writeError { throw BluettiNativeFailure.failed(code: "bluetooth", message: "Bluetooth write failed: " + error) }
            } else {
                try wait(until: end, message: "Bluetooth write queue did not become ready.") { peripheral.canSendWriteWithoutResponse }
                peripheral.writeValue(part, for: characteristic, type: kind)
            }
            offset = finish
        }
    }

    private func nextFrame(until end: TimeInterval) throws -> BluettiFrame {
        while true {
            try check()
            if let frame = try codec.next() { return frame }
            guard now < end else { throw BluettiNativeFailure.failed(code: "timeout", message: "Timed out waiting for the AC50P reply.") }
            pump(until: min(deadline, end))
        }
    }

    private func receiveKey(_ type: UInt8, until end: TimeInterval) throws -> [UInt8] {
        while true {
            if case .keyExchange(let frame) = try nextFrame(until: end),
               try BluettiIoTProtocol.parseKeyExchange(frame).type == type { return frame }
        }
    }

    func handshake() throws {
        let challenge = try receiveKey(1, until: min(deadline, now + 8))
        let type2 = try codec.crypto.replyChallenge(challenge)
        do { try write(type2, response: true) }
        catch {
            try check()
            // Only type2 prefers ATT Write Request. Some stacks expose only
            // Write Command; preserve the upstream's bounded fallback.
            try write(type2, response: false)
        }
        let peer = try receiveKey(4, until: min(deadline, now + 5))
        let type5 = try codec.crypto.replyPeer(peer)
        try write(type5, response: false)
        let accepted: [UInt8]
        do { accepted = try receiveKey(6, until: min(deadline, now + 2.5)) }
        catch let error as BluettiNativeFailure where error.code == "timeout" {
            try check()
            // Same bytes, signature and ephemeral pair. Never regenerate type5.
            try write(type5, response: false)
            accepted = try receiveKey(6, until: min(deadline, now + 1.5))
        }
        try codec.crypto.acceptPeer(accepted)
        try write(codec.crypto.encrypt([0x01]), response: false)
        let drainEnd = min(deadline, now + 0.4)
        while now < drainEnd {
            do { _ = try nextFrame(until: drainEnd) }
            catch let error as BluettiNativeFailure where error.code == "timeout" { break }
        }
    }

    func readRegisters() throws -> [UInt16: UInt16] {
        var result: [UInt16: UInt16] = [:]
        for (address, quantity) in BluettiIoTProtocol.pollWindows {
            let command = try BluettiIoTProtocol.readHolding(address: address, quantity: quantity)
            try write(codec.crypto.encrypt(command), response: false)
            let end = min(deadline, now + 3)
            var values: [UInt16]?
            while values == nil {
                if case .application(let plain) = try nextFrame(until: end) {
                    if plain.isEmpty || plain == [0x01] { continue } // Delayed session-ping acknowledgement.
                    values = try BluettiIoTProtocol.parseHolding(plain, quantity: quantity)
                }
            }
            for (index, value) in values!.enumerated() { result[address + UInt16(index)] = value }
        }
        return result
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if closing { return }
        switch central.state {
        case .poweredOn, .unknown, .resetting: break
        case .poweredOff: failure = .failed(code: "bluetooth", message: "Bluetooth is off. Turn it on in System Settings.")
        case .unauthorized: failure = .failed(code: "permission", message: "Allow Bluetooth access for BluettiBar in System Settings > Privacy & Security > Bluetooth.")
        case .unsupported: failure = .failed(code: "bluetooth", message: "This Mac does not support Bluetooth Low Energy.")
        @unknown default: failure = .failed(code: "bluetooth", message: "Bluetooth is unavailable.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !closing, let rawName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.uppercased().contains("AC50P") else { return }
        let id = peripheral.identifier.uuidString.lowercased()
        discovered[id] = (peripheral, BluettiNativeDevice(id: id, name: name))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        connected = true
        connectionFinished = true
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        connectionError = error?.localizedDescription ?? "AC50P connection failed. Close the BLUETTI phone app and try again."
        connectionFinished = true
        connected = false
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        connected = false
        if !closing && !expectingDisconnect {
            failure = .failed(code: "bluetooth", message: error?.localizedDescription ?? "AC50P disconnected during the reading.")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral, !closing else { return }
        if let error = error { failure = .failed(code: "bluetooth", message: "Service discovery failed: " + error.localizedDescription); return }
        service = peripheral.services?.first { $0.uuid == Self.serviceID }
        if service == nil { failure = .failed(code: "bluetooth", message: "AC50P service FF00 was not found.") }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, service.uuid == Self.serviceID, !closing else { return }
        if let error = error { failure = .failed(code: "bluetooth", message: "Characteristic discovery failed: " + error.localizedDescription); return }
        notifyCharacteristic = service.characteristics?.first { $0.uuid == Self.notifyID }
        writeCharacteristic = service.characteristics?.first { $0.uuid == Self.writeID }
        if notifyCharacteristic == nil || writeCharacteristic == nil {
            failure = .failed(code: "bluetooth", message: "AC50P characteristics FF01/FF02 were not found.")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic.uuid == Self.notifyID, !closing else { return }
        if let error = error { failure = .failed(code: "bluetooth", message: "Notifications failed: " + error.localizedDescription); return }
        notifyReady = characteristic.isNotifying
        if !notifyReady { failure = .failed(code: "bluetooth", message: "Station stopped Bluetooth notifications.") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic.uuid == Self.notifyID, !closing else { return }
        if let error = error { failure = .failed(code: "bluetooth", message: "Notification read failed: " + error.localizedDescription); return }
        guard let value = characteristic.value else { return }
        do { try codec.append(Array(value)) }
        catch let error as BluettiNativeFailure { failure = error }
        catch { failure = .failed(code: "protocol", message: "Invalid station notification.") }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic.uuid == Self.writeID, awaitingWrite else { return }
        writeError = error?.localizedDescription
        writeFinished = true
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // The synchronous writer checks canSendWriteWithoutResponse after this
        // delegate event wakes the main RunLoop.
    }
}
