import AppKit

struct LoadChartPoint {
    let timestamp: Date
    let watts: Double
    let startsSegment: Bool
}

struct LoadChartHistory {
    static let window: TimeInterval = 30 * 60
    private(set) var points: [LoadChartPoint] = []
    private var pendingGap = true

    // Supply watts only when BOTH AC and DC outputs were actually measured.
    // A genuine zero is valid; nil, negative and non-finite totals break the line.
    mutating func append(timestamp: Date, watts: Double?, maximumGap: TimeInterval) {
        guard timestamp.timeIntervalSince1970.isFinite,
              let watts = watts, watts.isFinite, watts >= 0 else {
            markGap()
            return
        }
        if let last = points.last {
            if timestamp == last.timestamp { return } // Do not repeat cached samples.
            if timestamp < last.timestamp { clear() } // Clock/station reset.
        }
        let gap = points.last.map {
            timestamp.timeIntervalSince($0.timestamp) > maximumGap
        } ?? true
        points.append(LoadChartPoint(timestamp: timestamp, watts: watts,
                                     startsSegment: pendingGap || gap))
        pendingGap = false
        points.removeAll { $0.timestamp < timestamp.addingTimeInterval(-Self.window) }
        // 361 points cover 30 minutes at the fastest supported 5-second poll.
        if points.count > 400 { points.removeFirst(points.count - 400) }
    }

    mutating func markGap() { pendingGap = true }

    mutating func clear() {
        points.removeAll()
        pendingGap = true
    }

    mutating func visiblePoints(at now: Date) -> [LoadChartPoint] {
        let cutoff = now.addingTimeInterval(-Self.window)
        points.removeAll { $0.timestamp < cutoff }
        return points.filter { $0.timestamp <= now }
    }
}

final class LoadGraphView: NSView {
    private var points: [LoadChartPoint] = []
    private var now = Date()
    private(set) var hasLine = false
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 106))
        autoresizingMask = [.width]
        toolTip = "AC and DC output power over the past 30 minutes."
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("BLUETTI output power in watts over time")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(points: [LoadChartPoint], now: Date) {
        self.now = now
        let cutoff = now.addingTimeInterval(-LoadChartHistory.window)
        self.points = points.filter {
            $0.timestamp >= cutoff && $0.timestamp <= now
                && $0.watts.isFinite && $0.watts >= 0
        }
        hasLine = zip(self.points, self.points.dropFirst()).contains { pair in
            !pair.1.startsSegment && pair.1.timestamp > pair.0.timestamp
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func scaleMaximum() -> Double {
        let peak = max(1.0, points.map { $0.watts }.max() ?? 0)
        let magnitude = pow(10.0, floor(log10(peak)))
        for step in [1.0, 2.0, 5.0, 10.0] {
            let candidate = step * magnitude
            if candidate.isFinite && candidate >= peak { return candidate }
        }
        return peak
    }

    private func wattsLabel(_ watts: Double) -> String {
        if watts >= 1_000_000 { return String(format: "%.1e W", watts) }
        return String(format: watts.rounded() == watts ? "%.0f W" : "%.1f W", watts)
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: bounds.minX + 44, y: bounds.minY + 24,
                          width: bounds.width - 56, height: bounds.height - 36)
        guard plot.width > 0, plot.height > 0 else { return }
        let available = points.first.map { now.timeIntervalSince($0.timestamp) } ?? 60
        let span = min(LoadChartHistory.window, max(60, available))
        let start = now.addingTimeInterval(-span)
        let maximum = scaleMaximum()
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for fraction in [0.0, 0.5, 1.0] {
            let y = plot.minY + CGFloat(fraction) * plot.height
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
        }
        NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
        grid.stroke()

        let axis = NSBezierPath()
        axis.lineWidth = 0.7
        axis.move(to: NSPoint(x: plot.minX, y: plot.maxY))
        axis.line(to: NSPoint(x: plot.minX, y: plot.minY))
        axis.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        for fraction in [0.0, 0.5, 1.0] {
            let x = plot.minX + CGFloat(fraction) * plot.width
            axis.move(to: NSPoint(x: x, y: plot.minY))
            axis.line(to: NSPoint(x: x, y: plot.minY - 3))
        }
        NSColor.tertiaryLabelColor.setStroke()
        axis.stroke()

        for fraction in [0.0, 0.5, 1.0] {
            let label = wattsLabel(maximum * fraction) as NSString
            let size = label.size(withAttributes: labelAttributes)
            label.draw(at: NSPoint(x: max(bounds.minX + 2, plot.minX - 6 - size.width),
                                   y: plot.minY + CGFloat(fraction) * plot.height - size.height / 2),
                       withAttributes: labelAttributes)
        }
        timeFormatter.timeZone = .current
        for fraction in [0.0, 0.5, 1.0] {
            let time = start.addingTimeInterval(span * fraction)
            let label = timeFormatter.string(from: time) as NSString
            let size = label.size(withAttributes: labelAttributes)
            let center = plot.minX + CGFloat(fraction) * plot.width
            let x = min(bounds.maxX - size.width - 2,
                        max(bounds.minX + 2, center - size.width / 2))
            label.draw(at: NSPoint(x: x, y: plot.minY - 17), withAttributes: labelAttributes)
        }

        // Axes remain visible before two genuine contiguous samples exist.
        // No dots, interpolated missing samples, or extension to the current time.
        guard hasLine else { return }
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for (index, point) in points.enumerated() {
            let x = plot.minX + CGFloat(point.timestamp.timeIntervalSince(start) / span) * plot.width
            let y = plot.minY + CGFloat(point.watts / maximum) * plot.height
            let position = NSPoint(x: x, y: y)
            if index == 0 || point.startsSegment { path.move(to: position) }
            else { path.line(to: position) }
        }
        NSColor.systemBlue.setStroke()
        path.stroke()
    }
}
