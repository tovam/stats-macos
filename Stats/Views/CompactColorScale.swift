//
//  CompactColorScale.swift
//  Stats
//

import Cocoa
import Kit

internal extension Notification.Name {
    static let compactCPUUsage = Notification.Name("compactCPUUsage")
    static let compactRAMUsage = Notification.Name("compactRAMUsage")
    static let compactDiskFree = Notification.Name("compactDiskFree")
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

    var defaultRange: ClosedRange<Double> {
        switch self {
        case .cpu, .ram, .free: return 0...100
        case .swap: return 0...16
        }
    }

    var defaultConfiguration: CompactColorScaleConfiguration {
        CompactColorScaleConfiguration(
            minimum: self.defaultRange.lowerBound,
            maximum: self.defaultRange.upperBound,
            mode: .linear,
            stops: zip(self.defaultThresholds, CompactColorScale.legacyColors).map {
                CompactColorStop(value: $0.0, color: $0.1)
            }
        )
    }
}

internal enum CompactScaleMode: String, Codable, CaseIterable {
    case linear
    case logarithmic

    var title: String {
        switch self {
        case .linear: return "Linear"
        case .logarithmic: return "Log"
        }
    }
}

internal struct CompactColorStop: Codable, Equatable {
    var id: UUID
    var value: Double
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(id: UUID = UUID(), value: Double, color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        self.id = id
        self.value = value
        self.red = Double(rgb.redComponent)
        self.green = Double(rgb.greenComponent)
        self.blue = Double(rgb.blueComponent)
        self.alpha = Double(rgb.alphaComponent)
    }

    var color: NSColor {
        NSColor(
            deviceRed: CGFloat(self.red),
            green: CGFloat(self.green),
            blue: CGFloat(self.blue),
            alpha: CGFloat(self.alpha)
        )
    }

    mutating func setColor(_ color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        self.red = Double(rgb.redComponent)
        self.green = Double(rgb.greenComponent)
        self.blue = Double(rgb.blueComponent)
        self.alpha = Double(rgb.alphaComponent)
    }
}

internal struct CompactColorScaleConfiguration: Codable, Equatable {
    var minimum: Double
    var maximum: Double
    var mode: CompactScaleMode
    var stops: [CompactColorStop]

    var isValid: Bool {
        guard self.minimum.isFinite, self.maximum.isFinite, self.minimum < self.maximum,
              self.stops.count >= 2 else { return false }
        return self.stops.allSatisfy { stop in
            stop.value.isFinite && stop.value >= self.minimum && stop.value <= self.maximum &&
                [stop.red, stop.green, stop.blue, stop.alpha].allSatisfy {
                    $0.isFinite && $0 >= 0 && $0 <= 1
                }
        }
    }
}

internal struct CompactColorScale {
    static let legacyColors: [NSColor] = [
        .white,
        .systemYellow,
        .systemOrange,
        .systemRed,
        .systemPurple
    ]

    let configuration: CompactColorScaleConfiguration

    func color(for value: Double) -> NSColor {
        let stops = self.configuration.stops.enumerated().sorted { lhs, rhs in
            lhs.element.value == rhs.element.value ? lhs.offset < rhs.offset : lhs.element.value < rhs.element.value
        }.map(\.element)
        guard let first = stops.first, let last = stops.last else { return .white }
        if value < first.value { return first.color }
        if value >= last.value { return last.color }

        for index in 0..<(stops.count - 1) {
            let start = stops[index]
            let end = stops[index + 1]
            if end.value <= start.value || value >= end.value { continue }
            let startPosition = self.position(for: start.value)
            let endPosition = self.position(for: end.value)
            let valuePosition = self.position(for: value)
            let distance = endPosition - startPosition
            let progress = distance == 0 ? 1 : (valuePosition - startPosition) / distance
            return Self.interpolate(from: start.color, to: end.color, progress: progress)
        }

        return last.color
    }

    func position(for value: Double) -> Double {
        let minimum = self.configuration.minimum
        let span = self.configuration.maximum - minimum
        guard span > 0 else { return 0 }
        let offset = min(span, max(0, value - minimum))
        switch self.configuration.mode {
        case .linear:
            return offset / span
        case .logarithmic:
            return log1p(offset) / log1p(span)
        }
    }

    func value(at position: Double) -> Double {
        let minimum = self.configuration.minimum
        let span = self.configuration.maximum - minimum
        let clamped = min(1, max(0, position))
        switch self.configuration.mode {
        case .linear:
            return minimum + (clamped * span)
        case .logarithmic:
            return minimum + expm1(clamped * log1p(span))
        }
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

    func configuration(for metric: CompactMetric) -> CompactColorScaleConfiguration {
        if let data = Store.shared.data(key: self.key(for: metric)),
           let configuration = try? JSONDecoder().decode(CompactColorScaleConfiguration.self, from: data),
           configuration.isValid {
            return configuration
        }

        let migrated = self.migrateLegacyConfiguration(for: metric)
        if let data = try? JSONEncoder().encode(migrated) {
            Store.shared.set(key: self.key(for: metric), value: data)
        }
        return migrated
    }

    func scale(for metric: CompactMetric) -> CompactColorScale {
        CompactColorScale(configuration: self.configuration(for: metric))
    }

    @discardableResult
    func save(_ configuration: CompactColorScaleConfiguration, for metric: CompactMetric) -> Bool {
        guard configuration.isValid, let data = try? JSONEncoder().encode(configuration) else { return false }
        Store.shared.set(key: self.key(for: metric), value: data)
        NotificationCenter.default.post(name: .compactColorScaleChanged, object: metric)
        return true
    }

    func reset(_ metric: CompactMetric) -> CompactColorScaleConfiguration {
        let configuration = metric.defaultConfiguration
        _ = self.save(configuration, for: metric)
        return configuration
    }

    private func key(for metric: CompactMetric) -> String {
        "compact_color_gradient_\(metric.rawValue)"
    }

    private func migrateLegacyConfiguration(for metric: CompactMetric) -> CompactColorScaleConfiguration {
        let legacyKey = "compact_color_scale_\(metric.rawValue)"
        guard Store.shared.exist(key: legacyKey) else { return metric.defaultConfiguration }
        let stored = Store.shared.string(key: legacyKey, defaultValue: "")
        let values = stored.split(separator: ",").compactMap { Double($0) }
        guard values.count == CompactColorScale.legacyColors.count,
              values.allSatisfy(\.isFinite) else { return metric.defaultConfiguration }

        var minimum = metric.defaultRange.lowerBound
        var maximum = metric.defaultRange.upperBound
        if let first = values.min() { minimum = min(minimum, first) }
        if let last = values.max() { maximum = max(maximum, last) }
        guard minimum < maximum else { return metric.defaultConfiguration }

        return CompactColorScaleConfiguration(
            minimum: minimum,
            maximum: maximum,
            mode: .linear,
            stops: zip(values, CompactColorScale.legacyColors).map {
                CompactColorStop(value: $0.0, color: $0.1)
            }
        )
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
        self.colors[metric] ?? .white
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

internal final class CompactCombinedBridge: NSObject {
    private weak var view: CompactSystemView?

    init(view: CompactSystemView) {
        self.view = view
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.listenForCPUUsage),
            name: .compactCPUUsage,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.listenForRAMUsage),
            name: .compactRAMUsage,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.listenForDiskFree),
            name: .compactDiskFree,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.listenForColorScaleChange),
            name: .compactColorScaleChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.listenForUpdateStateChange),
            name: .compactUpdateStateChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func listenForCPUUsage(_ notification: Notification) {
        guard let value = notification.object as? Double else { return }
        self.view?.setCPU(value)
    }

    @objc private func listenForRAMUsage(_ notification: Notification) {
        guard let value = notification.object as? [String: Double],
              let usage = value["usage"], let swap = value["swap"] else { return }
        self.view?.setRAM(usage, swap: swap)
    }

    @objc private func listenForDiskFree(_ notification: Notification) {
        guard let value = notification.object as? Int64 else { return }
        self.view?.setDiskFree(value)
    }

    @objc private func listenForColorScaleChange() {
        self.view?.refreshColors()
    }

    @objc private func listenForUpdateStateChange() {
        self.view?.refreshUpdateIndicator()
    }
}

internal final class CompactSystemView: NSView {
    internal var widthCallback: ((CGFloat) -> Void)?

    private let horizontalPadding: CGFloat = 4
    private let baseColumnSpacing: CGFloat = 7
    private let labelValueSpacing: CGFloat = 2
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private let bytesPerGibibyte: Double = 1_073_741_824
    private let colorAnimator = CompactColorAnimator()
    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.usesSignificantDigits = true
        formatter.minimumSignificantDigits = 2
        formatter.maximumSignificantDigits = 2
        return formatter
    }()
    private let smallGigabytesFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private var cpu: Double?
    private var ram: Double?
    private var diskFree: Int64?
    private var swap: Double?
    private var firstLabelWidth: CGFloat = 0
    private var firstValueWidth: CGFloat = 0
    private var secondLabelWidth: CGFloat = 0
    private var secondValueWidth: CGFloat = 0
    private var firstColumnWidth: CGFloat = 0

    private var configuredSpacing: CGFloat {
        CGFloat(Int(Store.shared.string(key: "CombinedModules_spacing", defaultValue: "none")) ?? 0)
    }
    private var separator: Bool {
        Store.shared.bool(key: "CombinedModules_separator", defaultValue: false)
    }
    private var columnSpacing: CGFloat {
        if self.separator {
            return self.baseColumnSpacing + (self.configuredSpacing * 2) + 4
        }
        return self.baseColumnSpacing + self.configuredSpacing
    }
    private var updateIndicatorWidth: CGFloat {
        CompactUpdateMonitor.shared.needsAttention ? 9 : 0
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: Constants.Widget.height))
        self.colorAnimator.onUpdate = { [weak self] in
            self?.needsDisplay = true
        }
        self.recalculateWidth()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    internal func setCPU(_ value: Double) {
        DispatchQueue.main.async {
            self.cpu = value
            self.updateColor(.cpu)
            self.refresh()
        }
    }

    internal func setRAM(_ value: Double, swap: Double) {
        DispatchQueue.main.async {
            self.ram = value
            self.swap = swap
            self.updateColor(.ram)
            self.updateColor(.swap)
            self.refresh()
        }
    }

    internal func setDiskFree(_ value: Int64) {
        DispatchQueue.main.async {
            self.diskFree = value
            self.updateColor(.free)
            self.refresh()
        }
    }

    internal func refreshColors() {
        DispatchQueue.main.async {
            CompactMetric.allCases.forEach(self.updateColor)
        }
    }

    internal func refreshUpdateIndicator() {
        DispatchQueue.main.async {
            self.recalculateWidth()
        }
    }

    internal func recalculateWidth() {
        self.firstLabelWidth = max(self.width(of: self.cpuLabel), self.width(of: self.ramLabel))
        self.firstValueWidth = max(self.width(of: self.cpuValue), self.width(of: self.ramValue))
        self.secondLabelWidth = max(self.width(of: self.diskFreeLabel), self.width(of: self.swapLabel))
        self.secondValueWidth = max(self.width(of: self.diskFreeValue), self.width(of: self.swapValue))

        let first = self.firstLabelWidth + self.labelValueSpacing + self.firstValueWidth
        let second = self.secondLabelWidth + self.labelValueSpacing + self.secondValueWidth
        self.firstColumnWidth = first

        let width = (self.horizontalPadding * 2) + first + self.columnSpacing + second +
            self.updateIndicatorWidth
        self.setFrameSize(NSSize(width: width, height: Constants.Widget.height))
        self.widthCallback?(width)
        self.needsDisplay = true
    }

    internal func openModule(at point: NSPoint, window: NSWindow, modules: [Module]) {
        let moduleName = self.module(at: point)
        guard let module = modules.first(where: { $0.name == moduleName }) else { return }

        var userInfo: [String: Any] = [
            "module": module.name,
            "origin": window.frame.origin,
            "center": window.frame.width / 2
        ]
        if let widget = module.menuBar.activeWidgets.first {
            userInfo["widget"] = widget.type
        }
        NotificationCenter.default.post(name: .togglePopup, object: nil, userInfo: userInfo)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let firstX = self.horizontalPadding
        let secondX = firstX + self.firstColumnWidth + self.columnSpacing
        if self.separator {
            let separatorX = firstX + self.firstColumnWidth + (self.columnSpacing / 2)
            NSColor.textColor.withAlphaComponent(0.35).setFill()
            NSBezierPath.fill(NSRect(x: separatorX.rounded(.down), y: 3, width: 1, height: self.bounds.height - 6))
        }

        self.draw(label: self.cpuLabel, value: self.cpuValue, metric: .cpu, x: firstX, labelWidth: self.firstLabelWidth, valueWidth: self.firstValueWidth, top: true)
        self.draw(label: self.ramLabel, value: self.ramValue, metric: .ram, x: firstX, labelWidth: self.firstLabelWidth, valueWidth: self.firstValueWidth, top: false)
        self.draw(label: self.diskFreeLabel, value: self.diskFreeValue, metric: .free, x: secondX, labelWidth: self.secondLabelWidth, valueWidth: self.secondValueWidth, top: true)
        self.draw(label: self.swapLabel, value: self.swapValue, metric: .swap, x: secondX, labelWidth: self.secondLabelWidth, valueWidth: self.secondValueWidth, top: false)
        if CompactUpdateMonitor.shared.needsAttention {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: self.bounds.maxX - 6,
                y: (self.bounds.midY - 2.5).rounded(.down),
                width: 5,
                height: 5
            )).fill()
        }
    }

    private func refresh() {
        self.recalculateWidth()
        self.needsDisplay = true
    }

    private func module(at point: NSPoint) -> String {
        let firstColumnMaxX = self.horizontalPadding + self.firstColumnWidth + (self.columnSpacing / 2)
        if point.x <= firstColumnMaxX {
            return point.y >= self.bounds.midY ? "CPU" : "RAM"
        }
        return point.y >= self.bounds.midY ? "Disk" : "RAM"
    }

    private func draw(
        label: String,
        value: String,
        metric: CompactMetric,
        x: CGFloat,
        labelWidth: CGFloat,
        valueWidth: CGFloat,
        top: Bool
    ) {
        let rowHeight = self.bounds.height / 2
        let labelRect = NSRect(
            x: x,
            y: top ? rowHeight + 1 : 1,
            width: labelWidth,
            height: rowHeight
        )
        let valueRect = NSRect(
            x: x + labelWidth + self.labelValueSpacing,
            y: labelRect.origin.y,
            width: valueWidth,
            height: rowHeight
        )
        self.draw(label, in: labelRect, alignment: .center, color: NSColor.textColor.withAlphaComponent(0.7))
        self.draw(value, in: valueRect, alignment: .right, color: self.colorAnimator.color(for: metric))
    }

    private func draw(_ text: String, in rect: NSRect, alignment: NSTextAlignment, color: NSColor) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        NSAttributedString(string: text, attributes: [
            .font: self.font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]).draw(with: rect)
    }

    private func width(of text: String) -> CGFloat {
        text.widthOfString(usingFont: self.font).rounded(.up) + 1
    }

    private var cpuLabel: String { "C" }
    private var ramLabel: String { "R" }
    private var diskFreeLabel: String { "Fr" }
    private var swapLabel: String { "Sw" }

    private func updateColor(_ metric: CompactMetric) {
        let value: Double?
        switch metric {
        case .cpu:
            value = self.cpu.map { $0 * 100 }
        case .ram:
            value = self.ram.map { $0 * 100 }
        case .free:
            value = self.diskFree.map { DiskSize($0).gigabytes }
        case .swap:
            value = self.swap.map { $0 / self.bytesPerGibibyte }
        }
        guard let value else { return }
        let color = CompactColorScaleStore.shared.scale(for: metric).color(for: value)
        self.colorAnimator.setTarget(color, for: metric)
    }

    private var cpuValue: String {
        guard let value = self.cpu else { return "-- %" }
        return "\(self.percentage(value)) %"
    }

    private var ramValue: String {
        guard let value = self.ram else { return "-- %" }
        return "\(self.percentage(value)) %"
    }

    private var diskFreeValue: String {
        guard let value = self.diskFree else { return "-- GB" }
        return "\(self.formatGigabytes(DiskSize(value).gigabytes)) GB"
    }

    private var swapValue: String {
        guard let value = self.swap else { return "-- GB" }
        return "\(self.formatGigabytes(value / self.bytesPerGibibyte)) GB"
    }

    private func significant(_ value: Double) -> String {
        self.numberFormatter.string(from: NSNumber(value: max(0, value))) ?? "0"
    }

    private func percentage(_ value: Double) -> String {
        self.significant(min(100, max(0, value * 100)))
    }

    private func formatGigabytes(_ gigabytes: Double) -> String {
        let value = max(0, gigabytes)
        if (value * 10).rounded() / 10 < 10 {
            return self.smallGigabytesFormatter.string(from: NSNumber(value: value)) ?? "0.0"
        }
        return self.significant(value)
    }
}

internal final class CompactCombinedView: NSObject, NSGestureRecognizerDelegate {
    private var menuBarItem: NSStatusItem?
    private let view = CompactSystemView()
    private var popup: PopupWindow?
    private var bridge: CompactCombinedBridge?

    private var status: Bool {
        Store.shared.bool(key: "CombinedModules", defaultValue: true)
    }
    private var activeModules: [Module] {
        modules.filter({ $0.enabled }).sorted(by: { $0.combinedPosition < $1.combinedPosition })
    }
    private var combinedModulesPopup: Bool {
        Store.shared.bool(key: "CombinedModules_popup", defaultValue: true)
    }

    override init() {
        super.init()

        self.bridge = CompactCombinedBridge(view: self.view)

        modules.forEach { module in
            module.menuBar.callback = { [weak self] in
                if let status = self?.status, status {
                    DispatchQueue.main.async {
                        self?.recalculate()
                    }
                }
            }
        }

        self.popup = PopupWindow(
            title: "Combined modules",
            module: .combined,
            view: CompactCombinedPopup()
        ) { _ in }
        self.view.widthCallback = { [weak self] width in
            self?.menuBarItem?.length = width
            self?.updateToolTip()
        }

        if self.status {
            self.enable()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.listenForOneView),
            name: .toggleOneView,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.listenForModuleRearrange),
            name: .moduleRearrange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.listenForApplicationDidFinishLaunching),
            name: NSApplication.didFinishLaunchingNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    internal func enable() {
        self.menuBarItem = NSStatusBar.system.statusItem(withLength: 0)
        DispatchQueue.main.async {
            self.menuBarItem?.autosaveName = "CombinedModules"
        }
        self.menuBarItem?.button?.addSubview(self.view)
        self.menuBarItem?.button?.image = NSImage()
        self.menuBarItem?.button?.toolTip = localizedString("Combined modules")

        self.menuBarItem?.button?.target = self
        self.menuBarItem?.button?.action = #selector(self.handleClick)
        self.menuBarItem?.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])

        DispatchQueue.main.async {
            self.recalculate()
        }
    }

    internal func disable() {
        if let item = self.menuBarItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        self.menuBarItem = nil
    }

    private func recalculate() {
        self.view.recalculateWidth()
    }

    private func updateToolTip() {
        let base = localizedString("Combined modules")
        let state = CompactUpdateMonitor.shared.snapshot
        self.menuBarItem?.button?.toolTip = state.needsAttention
            ? "\(base)\n\(state.message)"
            : base
    }

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseDown {
            self.popup?.setIsVisible(false)
            NotificationCenter.default.post(
                name: .toggleSettings,
                object: nil,
                userInfo: ["module": "Settings"]
            )
            return
        }

        if self.combinedModulesPopup {
            self.togglePopup()
        } else {
            self.openModulePopup()
        }
    }

    private func openModulePopup() {
        guard let window = self.menuBarItem?.button?.window else { return }
        let location = self.view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        self.view.openModule(at: location, window: window, modules: self.activeModules)
    }

    private func togglePopup() {
        guard let popup = self.popup,
              let item = self.menuBarItem,
              let window = item.button?.window else { return }
        NSApplication.shared.windows.filter({ $0 is NSPanel }).forEach { $0.setIsVisible(false) }

        if popup.occlusionState.rawValue == 8192 {
            NSApplication.shared.activate(ignoringOtherApps: true)
            popup.contentView?.invalidateIntrinsicContentSize()

            let windowCenter = popup.contentView!.intrinsicContentSize.width / 2
            var x = window.frame.origin.x - windowCenter + (window.frame.width / 2)
            let y = window.frame.origin.y - popup.contentView!.intrinsicContentSize.height - 3

            let buttonPoint = NSPoint(x: window.frame.midX, y: window.frame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(buttonPoint) }) ?? NSScreen.main {
                if x + popup.contentView!.intrinsicContentSize.width > screen.frame.maxX {
                    x = screen.frame.maxX - popup.contentView!.intrinsicContentSize.width - 3
                }
                if x < screen.frame.minX {
                    x = screen.frame.minX + 3
                }
            }

            popup.setFrameOrigin(NSPoint(x: x, y: y))
            popup.setIsVisible(true)
        } else {
            popup.setIsVisible(false)
        }
    }

    @objc private func listenForOneView(_ notification: Notification) {
        guard notification.userInfo?["module"] == nil else { return }
        if self.status {
            self.enable()
        } else {
            self.disable()
        }
    }

    @objc private func listenForModuleRearrange() {
        self.recalculate()
    }

    @objc private func listenForApplicationDidFinishLaunching() {
        // parseVersion can reset the store during the same launch notification.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !Store.shared.exist(key: "CombinedModules") {
                Store.shared.set(key: "CombinedModules", value: true)
            }
            if self.status && self.menuBarItem == nil {
                self.enable()
            }
        }
    }
}

internal final class CompactCombinedPopup: NSView, Popup_p {
    private struct EmbeddedPopup {
        let module: Module
        let view: Popup_p
        let column: CompactPopupColumn
    }

    private let moduleOrder = [
        ModuleType.CPU.stringValue,
        ModuleType.RAM.stringValue,
        ModuleType.disk.stringValue,
        ModuleType.network.stringValue
    ]
    private let columnSpacing = Constants.Popup.spacing * 3
    private var embedded: [EmbeddedPopup] = []

    internal var keyboardShortcut: [UInt16]
    internal var sizeCallback: ((NSSize) -> Void)?

    init() {
        self.keyboardShortcut = Store.shared.array(
            key: "CombinedModules_popup_keyboardShortcut",
            defaultValue: []
        ) as? [UInt16] ?? []
        self.sizeCallback = nil

        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 0))

        self.prepareFrame()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.moduleStateChanged),
            name: .toggleModule,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .toggleModule, object: nil)
    }

    internal func settings() -> NSView? { nil }
    internal func appear() {
        guard self.embedded.isEmpty else { return }

        for module in self.orderedModules {
            guard let view = module.popupContentView else { continue }
            let column = CompactPopupColumn(title: module.name, content: view)
            self.addSubview(column)
            self.embedded.append(EmbeddedPopup(module: module, view: view, column: column))

            view.sizeCallback = { [weak self, weak column] size in
                column?.contentSizeDidChange(size)
                self?.layoutColumns()
            }
            module.setPopupContentActive(true)
            view.appear()
        }
        self.layoutColumns()
    }

    internal func disappear() {
        guard !self.embedded.isEmpty else { return }
        let current = self.embedded
        self.embedded.removeAll()

        for entry in current {
            entry.view.disappear()
            entry.module.setPopupContentActive(false)
            entry.module.restorePopupContent()
            entry.column.removeFromSuperview()
        }
        self.prepareFrame()
    }

    internal func setKeyboardShortcut(_ binding: [UInt16]) {
        self.keyboardShortcut = binding
        Store.shared.set(key: "CombinedModules_popup_keyboardShortcut", value: binding)
    }

    private var orderedModules: [Module] {
        self.moduleOrder.compactMap { name in
            modules.first(where: {
                $0.name == name && $0.enabled && $0.available && $0.popupContentView != nil
            })
        }
    }

    @objc private func moduleStateChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.window?.isVisible == true {
                self.disappear()
                self.appear()
            } else {
                self.prepareFrame()
            }
        }
    }

    private func prepareFrame() {
        let views = self.orderedModules.compactMap(\.popupContentView)
        guard !views.isEmpty else {
            self.setFrameSize(NSSize(width: Constants.Popup.width, height: 0))
            self.sizeCallback?(self.frame.size)
            return
        }

        let width = views.map(\.frame.width).reduce(0, +) +
            (CGFloat(views.count - 1) * self.columnSpacing)
        let height = views.map { $0.frame.height + CompactPopupColumn.headerHeight }.max() ?? 0
        self.updateSize(NSSize(width: width, height: height))
    }

    private func layoutColumns() {
        guard !self.embedded.isEmpty else {
            self.prepareFrame()
            return
        }

        let height = self.embedded.map { $0.column.requiredSize.height }.max() ?? 0
        var x: CGFloat = 0
        for entry in self.embedded {
            let size = entry.column.requiredSize
            entry.column.setFrameOrigin(NSPoint(x: x, y: height - size.height))
            entry.column.setFrameSize(size)
            entry.column.layoutContent()
            x += size.width + self.columnSpacing
        }
        x -= self.columnSpacing
        self.updateSize(NSSize(width: max(Constants.Popup.width, x), height: height))
    }

    private func updateSize(_ size: NSSize) {
        guard self.frame.size != size else { return }
        self.setFrameSize(size)
        self.sizeCallback?(size)
    }
}

private final class CompactPopupColumn: NSView {
    static let headerHeight: CGFloat = 25

    private let content: Popup_p
    private let titleField: NSTextField

    var requiredSize: NSSize {
        NSSize(
            width: max(Constants.Popup.width, self.content.frame.width),
            height: self.content.frame.height + Self.headerHeight
        )
    }

    init(title: String, content: Popup_p) {
        self.content = content
        self.titleField = NSTextField(labelWithString: localizedString(title))
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: max(Constants.Popup.width, content.frame.width),
            height: content.frame.height + Self.headerHeight
        ))

        self.titleField.alignment = .center
        self.titleField.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        self.titleField.textColor = .secondaryLabelColor
        self.addSubview(content)
        self.addSubview(self.titleField)
        self.layoutContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func contentSizeDidChange(_ size: NSSize) {
        self.content.setFrameSize(size)
        self.setFrameSize(self.requiredSize)
        self.layoutContent()
    }

    func layoutContent() {
        let size = self.requiredSize
        self.content.setFrameOrigin(NSPoint(
            x: (size.width - self.content.frame.width) / 2,
            y: 0
        ))
        self.titleField.frame = NSRect(
            x: 0,
            y: self.content.frame.height + 4,
            width: size.width,
            height: Self.headerHeight - 4
        )
    }
}
