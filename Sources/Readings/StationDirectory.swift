import Foundation

/// Persist independently from BlueBar's normal preferences. Removing the main
/// app preferences does not remove this suite or the user's station aliases.
struct BlueBarKnownStation: Codable, Equatable {
    let key: String
    var deviceID: String?
    var bluetoothName: String
    var model: String
    var alias: String?
    var seenNames: [String]
    var lastSeen: Date

    var displayName: String { alias ?? bluetoothName }
    /// Pass this to `bluetti --device`; aliases are display text, not selectors.
    var selector: String { deviceID ?? bluetoothName }
}

/// Use from the main thread, where the menu owns its station state.
final class BlueBarStationDirectory {
    static let suiteName = "com.local.bluebar.aliases"
    private static let storageKey = "stationDirectory.v1"

    private struct Saved: Codable {
        var version = 1
        var stations: [BlueBarKnownStation]
    }

    private let defaults: UserDefaults?
    private var records: [String: BlueBarKnownStation] = [:]

    init(defaults: UserDefaults? = UserDefaults(suiteName: BlueBarStationDirectory.suiteName)) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == 1 {
            for station in saved.stations {
                guard !station.bluetoothName.isEmpty else { continue }
                records[station.key] = station
            }
        }
    }

    /// Stable saved choices, including stations currently outside Bluetooth range.
    var stations: [BlueBarKnownStation] {
        let values = Array(records.values)
        return values.filter { value in
            // Keep an unresolved alias on disk, but do not offer an ambiguous
            // name-only selector after distinct UUIDs have advertised that name.
            value.deviceID != nil || !values.contains { other in
                other.deviceID != nil && value.seenNames.contains { other.seenNames.contains($0) }
            }
        }.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return comparison == .orderedSame ? $0.key < $1.key : comparison == .orderedAscending
        }
    }

    /// Returns nil for an ambiguous name when an authoritative ID is unavailable.
    func station(deviceID: String?, bluetoothName: String) -> BlueBarKnownStation? {
        if let id = Self.normalizedID(deviceID) {
            return records["id:" + id]
        }
        let name = Self.normalizedName(bluetoothName)
        let matches = records.values.filter { $0.seenNames.contains(name) }
        return matches.count == 1 ? matches[0] : nil
    }

    func displayName(deviceID: String?, bluetoothName: String) -> String {
        station(deviceID: deviceID, bluetoothName: bluetoothName)?.displayName ?? bluetoothName
    }

    /// Observe a station from a successful CLI status or scan. UUID/ID takes
    /// precedence. A name-only record is promoted once, only if that name has
    /// no existing authoritative binding to another station.
    @discardableResult
    func observe(deviceID: String?, bluetoothName: String, model: String = "AC50P",
                 allowNamePromotion: Bool = true) -> BlueBarKnownStation? {
        let name = bluetoothName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !Self.hasControls(name) else { return nil }
        let nameKey = Self.normalizedName(name)
        let id = Self.normalizedID(deviceID)
        let matches = records.values.filter { $0.seenNames.contains(nameKey) }
        let key: String
        var record: BlueBarKnownStation

        if let id = id {
            key = "id:" + id
            if let existing = records[key] {
                record = existing
            } else if allowNamePromotion, matches.count == 1,
                      let provisional = matches.first, provisional.deviceID == nil {
                records.removeValue(forKey: provisional.key)
                record = BlueBarKnownStation(key: key, deviceID: id, bluetoothName: name,
                    model: model, alias: provisional.alias, seenNames: provisional.seenNames,
                    lastSeen: Date())
            } else {
                // Another UUID with the same BLE name never inherits its alias.
                record = BlueBarKnownStation(key: key, deviceID: id, bluetoothName: name,
                    model: model, alias: nil, seenNames: [], lastSeen: Date())
            }
        } else if matches.count == 1, let existing = matches.first {
            key = existing.key
            record = existing
        } else if matches.isEmpty {
            key = "name:" + nameKey
            record = BlueBarKnownStation(key: key, deviceID: nil, bluetoothName: name,
                model: model, alias: nil, seenNames: [], lastSeen: Date())
        } else {
            // Two known UUIDs sharing a name cannot be resolved by that name.
            return nil
        }

        record.bluetoothName = name
        record.model = model
        record.lastSeen = Date()
        if !record.seenNames.contains(nameKey) { record.seenNames.append(nameKey) }
        records[key] = record
        save()
        return record
    }

    @discardableResult
    func ingestStatus(_ json: [String: Any]) -> BlueBarKnownStation? {
        guard json["ok"] as? Bool == true, let name = json["device"] as? String else { return nil }
        return observe(deviceID: json["device_id"] as? String, bluetoothName: name,
            model: json["model"] as? String ?? "AC50P")
    }

    @discardableResult
    func ingestScan(_ json: [String: Any]) -> [BlueBarKnownStation] {
        guard json["ok"] as? Bool == true, let devices = json["devices"] as? [[String: Any]] else { return [] }
        // Inspect the entire scan before promoting a name-only alias. Otherwise
        // the first of two same-name UUIDs could receive it arbitrarily.
        var idsByName: [String: Set<String>] = [:]
        for device in devices {
            if let name = device["name"] as? String, let id = Self.normalizedID(device["id"] as? String) {
                idsByName[Self.normalizedName(name), default: []].insert(id)
            }
        }
        return devices.compactMap { device in
            guard let name = device["name"] as? String else { return nil }
            return observe(deviceID: device["id"] as? String, bluetoothName: name,
                model: device["model"] as? String ?? "AC50P",
                allowNamePromotion: (idsByName[Self.normalizedName(name)]?.count ?? 0) <= 1)
        }
    }

    /// Empty text removes the alias without forgetting the station. A nil result
    /// means a name-only identity was ambiguous; no station's alias was changed.
    @discardableResult
    func setAlias(_ text: String, deviceID: String?, bluetoothName: String,
                  model: String = "AC50P") -> BlueBarKnownStation? {
        guard var record = observe(deviceID: deviceID, bluetoothName: bluetoothName, model: model) else { return nil }
        let alias = Self.sanitizedAlias(text)
        record.alias = alias.isEmpty ? nil : alias
        records[record.key] = record
        save()
        return record
    }

    static func sanitizedAlias(_ value: String) -> String {
        let filtered = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let clean = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(48))
    }

    private static func hasControls(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func normalizedID(_ value: String?) -> String? {
        guard let value = value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !hasControls(clean) else { return nil }
        // CoreBluetooth's UUID is authoritative; preserve other backend IDs too.
        return (UUID(uuidString: clean)?.uuidString ?? clean).lowercased()
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(stations: Array(records.values))) else { return }
        defaults?.set(data, forKey: Self.storageKey)
    }
}
