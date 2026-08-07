//
//  CompactColorScale.swift
//  Stats
//

import Cocoa
import Kit

internal extension Notification.Name {
    static let compactColorScaleChanged = Notification.Name("compactColorScaleChanged")
}

internal enum CompactMetric: String, CaseIterable {
    case cpu
    case ram
    case free
    case swap

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .ram: return "RAM"
        case .free: return "Free"
        case .swap: return "Swap"
        }
    }

    var unit: String {
        switch self {
        case .cpu, .ram: return "%"
        case .free, .swap: return "GB"
        }
    }

    var defaultThresholds: [Double] {
        switch self {
        case .cpu, .ram: return [0, 50, 70, 85, 100]
        case .free: return [100, 50, 25, 10, 5]
        case .swap: return [0, 2, 4, 8, 16]
        }
    }
}

internal enum CompactScaleDirection: Equatable {
    case increasing
    case decreasing
}

internal struct CompactColorScale {
    static let colors: [NSColor] = [
        .white,
        .systemYellow,
        .systemOrange,
        .systemRed,
        .systemPurple
    ]

    let thresholds: [Double]

    var direction: CompactScaleDirection? {
        Self.direction(of: self.thresholds)
    }

    static func direction(of values: [Double]) -> CompactScaleDirection? {
        guard values.count == Self.colors.count, values.allSatisfy({ $0.isFinite }) else { return nil }

        let differences = zip(values.dropFirst(), values).map { next, previous in next - previous }
        if differences.allSatisfy({ $0 > 0 }) {
            return .increasing
        }
        if differences.allSatisfy({ $0 < 0 }) {
            return .decreasing
        }
        return nil
    }

    func color(for value: Double) -> NSColor {
        guard let direction = self.direction else { return Self.colors[0] }

        switch direction {
        case .increasing:
            if value <= self.thresholds[0] { return Self.colors[0] }
            if value >= self.thresholds[4] { return Self.colors[4] }
        case .decreasing:
            if value >= self.thresholds[0] { return Self.colors[0] }
            if value <= self.thresholds[4] { return Self.colors[4] }
        }

        for index in 0..<4 {
            let start = self.thresholds[index]
            let end = self.thresholds[index + 1]
            let isInside = direction == .increasing
                ? value >= start && value <= end
                : value <= start && value >= end
            if isInside {
                let progress = (value - start) / (end - start)
                return Self.interpolate(from: Self.colors[index], to: Self.colors[index + 1], progress: progress)
            }
        }

        return Self.colors[4]
    }

    static func interpolate(from: NSColor, to: NSColor, progress: Double) -> NSColor {
        let amount = CGFloat(min(1, max(0, progress)))
        guard let first = from.usingColorSpace(.deviceRGB),
              let second = to.usingColorSpace(.deviceRGB) else {
            return amount < 0.5 ? from : to
        }

        return NSColor(
            deviceRed: first.redComponent + ((second.redComponent - first.redComponent) * amount),
            green: first.greenComponent + ((second.greenComponent - first.greenComponent) * amount),
            blue: first.blueComponent + ((second.blueComponent - first.blueComponent) * amount),
            alpha: first.alphaComponent + ((second.alphaComponent - first.alphaComponent) * amount)
        )
    }
}

internal final class CompactColorScaleStore {
    static let shared = CompactColorScaleStore()

    private init() {}

    func thresholds(for metric: CompactMetric) -> [Double] {
        let fallback = self.serialize(metric.defaultThresholds)
        let stored = Store.shared.string(key: self.key(for: metric), defaultValue: fallback)
        let values = stored.split(separator: ",").compactMap { Double($0) }
        return CompactColorScale.direction(of: values) == nil ? metric.defaultThresholds : values
    }

    func scale(for metric: CompactMetric) -> CompactColorScale {
        CompactColorScale(thresholds: self.thresholds(for: metric))
    }

    @discardableResult
    func save(_ values: [Double], for metric: CompactMetric) -> Bool {
        guard CompactColorScale.direction(of: values) != nil else { return false }
        Store.shared.set(key: self.key(for: metric), value: self.serialize(values))
        NotificationCenter.default.post(name: .compactColorScaleChanged, object: metric)
        return true
    }

    private func key(for metric: CompactMetric) -> String {
        "compact_color_scale_\(metric.rawValue)"
    }

    private func serialize(_ values: [Double]) -> String {
        values.map { String($0) }.joined(separator: ",")
    }
}

internal final class CompactColorAnimator {
    var onUpdate: (() -> Void)?

    private struct Animation {
        let from: NSColor
        let to: NSColor
        let startedAt: TimeInterval
    }

    private let duration: TimeInterval = 0.35
    private var colors: [CompactMetric: NSColor] = [:]
    private var targets: [CompactMetric: NSColor] = [:]
    private var animations: [CompactMetric: Animation] = [:]
    private var timer: Timer?

    deinit {
        self.timer?.invalidate()
    }

    func color(for metric: CompactMetric) -> NSColor {
        self.colors[metric] ?? CompactColorScale.colors[0]
    }

    func setTarget(_ color: NSColor, for metric: CompactMetric, animated: Bool = true) {
        if let target = self.targets[metric], target.isEqual(color) {
            return
        }
        self.targets[metric] = color

        guard animated, let current = self.colors[metric] else {
            self.colors[metric] = color
            self.animations.removeValue(forKey: metric)
            self.onUpdate?()
            return
        }

        self.animations[metric] = Animation(
            from: current,
            to: color,
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        self.startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard self.timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        var completed: [CompactMetric] = []
        for (metric, animation) in self.animations {
            let progress = (now - animation.startedAt) / self.duration
            if progress >= 1 {
                self.colors[metric] = animation.to
                completed.append(metric)
            } else {
                self.colors[metric] = CompactColorScale.interpolate(
                    from: animation.from,
                    to: animation.to,
                    progress: progress
                )
            }
        }
        completed.forEach { self.animations.removeValue(forKey: $0) }

        self.onUpdate?()
        if self.animations.isEmpty {
            self.timer?.invalidate()
            self.timer = nil
        }
    }
}
