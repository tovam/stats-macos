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

    internal func recalculateWidth() {
        self.firstLabelWidth = max(self.width(of: self.cpuLabel), self.width(of: self.ramLabel))
        self.firstValueWidth = max(self.width(of: self.cpuValue), self.width(of: self.ramValue))
        self.secondLabelWidth = max(self.width(of: self.diskFreeLabel), self.width(of: self.swapLabel))
        self.secondValueWidth = max(self.width(of: self.diskFreeValue), self.width(of: self.swapValue))

        let first = self.firstLabelWidth + self.labelValueSpacing + self.firstValueWidth
        let second = self.secondLabelWidth + self.labelValueSpacing + self.secondValueWidth
        self.firstColumnWidth = first

        let width = (self.horizontalPadding * 2) + first + self.columnSpacing + second
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

    @objc private func handleClick() {
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

internal final class CompactCombinedPopup: NSStackView, Popup_p {
    private let moduleOrder = [
        ModuleType.CPU.stringValue,
        ModuleType.RAM.stringValue,
        ModuleType.disk.stringValue,
        ModuleType.network.stringValue
    ]

    internal var keyboardShortcut: [UInt16]
    internal var sizeCallback: ((NSSize) -> Void)?

    init() {
        self.keyboardShortcut = Store.shared.array(
            key: "CombinedModules_popup_keyboardShortcut",
            defaultValue: []
        ) as? [UInt16] ?? []
        self.sizeCallback = nil

        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 0))

        self.orientation = .horizontal
        self.distribution = .fillEqually
        self.alignment = .top
        self.spacing = Constants.Popup.spacing * 3

        self.reinit()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.reinit),
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
    internal func appear() {}
    internal func disappear() {}

    internal func setKeyboardShortcut(_ binding: [UInt16]) {
        self.keyboardShortcut = binding
        Store.shared.set(key: "CombinedModules_popup_keyboardShortcut", value: binding)
    }

    @objc private func reinit() {
        self.arrangedSubviews.forEach { view in
            self.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let portals = self.moduleOrder.compactMap { name in
            modules.first(where: { $0.name == name && $0.enabled })?.portal
        }
        portals.forEach(self.addArrangedSubview)

        guard !portals.isEmpty else {
            self.setFrameSize(NSSize(width: Constants.Popup.width, height: 0))
            self.sizeCallback?(self.frame.size)
            return
        }

        let columns = CGFloat(portals.count)
        let preferredWidth = (columns * Constants.Popup.width) + ((columns - 1) * self.spacing)
        let screenWidth = (NSScreen.main?.visibleFrame.width ?? preferredWidth)
            - (Constants.Popup.margins * 2) - 6
        let width = min(preferredWidth, max(Constants.Popup.width, screenWidth))
        let height = portals.map { $0.height }.max() ?? 0

        self.setFrameSize(NSSize(width: width, height: height))
        self.sizeCallback?(self.frame.size)
    }
}
