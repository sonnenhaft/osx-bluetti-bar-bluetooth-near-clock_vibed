import Foundation

enum PollInterval: Int, CaseIterable {
    case oneSecond = 1, threeSeconds = 3, fiveSeconds = 5
    case twentySeconds = 20, thirtySeconds = 30, oneMinute = 60, twoMinutes = 120

    var label: String { rawValue < 60 ? "\(rawValue)s" : "\(rawValue / 60)m" }
    var keepsConnection: Bool { rawValue <= 5 }
}
