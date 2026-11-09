import Foundation

struct StatusVisibility {
    var showOutput: Bool
    var showPercentage: Bool

    func canHidePercentage(for reading: Reading?) -> Bool {
        showOutput && reading?.outputWatts != nil
    }

    func showsPercentage(for reading: Reading?) -> Bool {
        !canHidePercentage(for: reading) || showPercentage
    }

    func title(for reading: Reading) -> String {
        var fields: [String] = []
        if showsPercentage(for: reading) { fields.append("\(reading.percent)%") }
        if showOutput, let watts = reading.outputWatts {
            fields.append(String(format: "%.0f W", watts))
        }
        return fields.joined(separator: " ")
    }

    mutating func togglePercentage(for reading: Reading?) {
        guard canHidePercentage(for: reading) else { return }
        showPercentage.toggle()
    }

    mutating func toggleOutput() {
        if showOutput { showPercentage = true }
        showOutput.toggle()
    }
}
