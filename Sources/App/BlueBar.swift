import AppKit

@main
private struct BluettiBarApplication {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let code = BluettiInstallation.handle(arguments: arguments) { exit(code) }
        if arguments.first == "--bluetti-helper" {
            exit(BluettiNativeCommand.run(arguments: Array(arguments.dropFirst())))
        }
        if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "bluetti" {
            exit(BluettiNativeCommand.run(arguments: arguments))
        }
        // The installer captures a previous reading before asking the old app to quit.
        // This mode reads no Bluetooth device, opens no UI and writes no API status file.
        if CommandLine.arguments.contains("--preserve-legacy-reading") {
            // This executable already belongs to com.local.bluebar. Its own domain
            // must use standard preferences, never a suite with the same identifier.
            let migrationDefaults = UserDefaults.standard
            let migrationCacheURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/BlueBar/status.json")
            let migrationDirectory = BlueBarStationDirectory()
            let migrationStore = BlueBarReadingStore(defaults: migrationDefaults,
                                                     fallbackStatusURL: migrationCacheURL)
            let migrationSelector = migrationDefaults.string(forKey: "stationIdentifier") ?? ""
            _ = migrationStore.reading(for: migrationSelector,
                                       knownStations: migrationDirectory.stations)
            // UserDefaults persists changes automatically. An absent legacy sample is
            // normal, and synchronize() is not a reliable installation success gate.
            exit(0)
        }
        guard BluettiInstallation.claimUIInstance() else { exit(0) }
        let application = NSApplication.shared
        let delegate = BlueBarDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
