//
//  CompactColorSettingsView.swift
//  Stats
//

import Cocoa
import Kit

internal final class CompactColorSettingsView: NSStackView {
    init() {
        super.init(frame: .zero)
        self.orientation = .vertical
        self.spacing = Constants.Settings.margin

        self.addArrangedSubview(PreferencesSection(
            title: "Compact display",
            subtitle: "Visual overrides; color gradients remain unchanged",
            [
                PreferencesRow(
                    "All white",
                    "Draw every label and value in white",
                    component: switchView(
                        action: #selector(self.toggleAllWhite),
                        state: CompactDisplayPreferences.allWhite
                    )
                ),
                PreferencesRow(
                    "Hide labels",
                    "Show values only, without C / R / Fr / Sw",
                    component: switchView(
                        action: #selector(self.toggleLabels),
                        state: CompactDisplayPreferences.hideLabels
                    )
                )
            ]
        ))

        let rows = CompactMetric.allCases.map { metric in
            PreferencesRow(
                metric.title,
                "Color gradient in \(metric.unit)",
                component: CompactScaleEditorView(metric: metric)
            )
        }
        self.addArrangedSubview(PreferencesSection(
            title: "Compact colors",
            subtitle: "Drag the colored handles; double-click the scale to add one",
            rows
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func toggleAllWhite(_ sender: NSSwitch) {
        CompactDisplayPreferences.allWhite = sender.state == .on
    }

    @objc private func toggleLabels(_ sender: NSSwitch) {
        CompactDisplayPreferences.hideLabels = sender.state == .on
    }
}

private final class CompactScaleEditorView: NSStackView, NSTextFieldDelegate {
    private let metric: CompactMetric
    private var configuration: CompactColorScaleConfiguration
    private let gradient: CompactGradientControl

    private let mode = NSSegmentedControl(
        labels: CompactScaleMode.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
    private let valueField = NSTextField(string: "")
    private let minimumField = NSTextField(string: "")
    private let maximumField = NSTextField(string: "")
    private let stateField = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "−", target: nil, action: nil)

    private let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    init(metric: CompactMetric) {
        self.metric = metric
        self.configuration = CompactColorScaleStore.shared.configuration(for: metric)
        self.gradient = CompactGradientControl(configuration: self.configuration, unit: metric.unit)
        super.init(frame: .zero)

        self.orientation = .vertical
        self.alignment = .trailing
        self.spacing = 5
        self.widthAnchor.constraint(equalToConstant: 350).isActive = true

        self.configureFields()
        self.addArrangedSubview(self.topControls())
        self.addArrangedSubview(self.gradient)
        self.addArrangedSubview(self.rangeControls())

        self.stateField.font = NSFont.systemFont(ofSize: 9)
        self.stateField.textColor = .secondaryLabelColor
        self.stateField.alignment = .right
        self.stateField.lineBreakMode = .byTruncatingTail
        self.stateField.maximumNumberOfLines = 1
        self.addArrangedSubview(self.stateField)

        self.gradient.onSelectionChange = { [weak self] stop in
            self?.show(stop: stop)
        }
        self.gradient.onConfigurationChange = { [weak self] configuration in
            guard let self else { return }
            self.configuration = configuration
            self.syncFields()
            self.save()
        }

        self.syncAllControls()
        self.showHelp()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureFields() {
        [self.valueField, self.minimumField, self.maximumField].forEach { field in
            field.alignment = .right
            field.controlSize = .small
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.delegate = self
            field.target = self
            field.action = #selector(self.commitFields)
            field.widthAnchor.constraint(equalToConstant: 54).isActive = true
        }
    }

    private func topControls() -> NSView {
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 5

        self.mode.controlSize = .small
        self.mode.target = self
        self.mode.action = #selector(self.selectScaleMode)

        let valueLabel = NSTextField(labelWithString: "Handle")
        valueLabel.font = NSFont.systemFont(ofSize: 10)
        valueLabel.textColor = .secondaryLabelColor

        let unit = NSTextField(labelWithString: self.metric.unit)
        unit.font = NSFont.systemFont(ofSize: 10)
        unit.textColor = .secondaryLabelColor

        self.colorWell.target = self
        self.colorWell.action = #selector(self.changeColor)
        self.colorWell.widthAnchor.constraint(equalToConstant: 30).isActive = true
        self.colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let addButton = NSButton(title: "+", target: self, action: #selector(self.addStop))
        addButton.toolTip = "Add a color handle"
        addButton.controlSize = .small
        addButton.bezelStyle = .rounded
        addButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        self.removeButton.target = self
        self.removeButton.action = #selector(self.removeStop)
        self.removeButton.toolTip = "Remove the selected handle"
        self.removeButton.controlSize = .small
        self.removeButton.bezelStyle = .rounded
        self.removeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        controls.addArrangedSubview(self.mode)
        controls.addArrangedSubview(NSView())
        controls.addArrangedSubview(valueLabel)
        controls.addArrangedSubview(self.valueField)
        controls.addArrangedSubview(unit)
        controls.addArrangedSubview(self.colorWell)
        controls.addArrangedSubview(addButton)
        controls.addArrangedSubview(self.removeButton)
        return controls
    }

    private func rangeControls() -> NSView {
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 5

        let range = NSTextField(labelWithString: "Range")
        range.font = NSFont.systemFont(ofSize: 10)
        range.textColor = .secondaryLabelColor
        let separator = NSTextField(labelWithString: "to")
        separator.font = NSFont.systemFont(ofSize: 10)
        separator.textColor = .secondaryLabelColor
        let unit = NSTextField(labelWithString: self.metric.unit)
        unit.font = NSFont.systemFont(ofSize: 10)
        unit.textColor = .secondaryLabelColor

        let reverse = NSButton(title: "Reverse", target: self, action: #selector(self.reverseScale))
        reverse.toolTip = "Mirror every handle across the scale"
        reverse.controlSize = .small
        reverse.bezelStyle = .rounded

        let reset = NSButton(title: "Reset", target: self, action: #selector(self.resetScale))
        reset.controlSize = .small
        reset.bezelStyle = .rounded

        controls.addArrangedSubview(range)
        controls.addArrangedSubview(self.minimumField)
        controls.addArrangedSubview(separator)
        controls.addArrangedSubview(self.maximumField)
        controls.addArrangedSubview(unit)
        controls.addArrangedSubview(NSView())
        controls.addArrangedSubview(reverse)
        controls.addArrangedSubview(reset)
        return controls
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        self.commitFields()
    }

    @objc private func commitFields() {
        guard let minimum = self.number(from: self.minimumField),
              let maximum = self.number(from: self.maximumField),
              minimum < maximum else {
            self.showError("The minimum must be lower than the maximum")
            self.syncFields()
            NSSound.beep()
            return
        }

        self.configuration.minimum = minimum
        self.configuration.maximum = maximum
        self.configuration.stops = self.configuration.stops.map { stop in
            var copy = stop
            copy.value = min(maximum, max(minimum, copy.value))
            return copy
        }

        if let selected = self.gradient.selectedStop,
           let value = self.number(from: self.valueField),
           let index = self.configuration.stops.firstIndex(where: { $0.id == selected.id }) {
            self.configuration.stops[index].value = min(maximum, max(minimum, value))
        }

        self.gradient.setConfiguration(self.configuration)
        self.syncAllControls()
        self.save()
    }

    @objc private func selectScaleMode() {
        guard CompactScaleMode.allCases.indices.contains(self.mode.selectedSegment) else { return }
        self.configuration.mode = CompactScaleMode.allCases[self.mode.selectedSegment]
        self.gradient.setConfiguration(self.configuration)
        self.save()
    }

    @objc private func changeColor() {
        guard let selected = self.gradient.selectedStop,
              let index = self.configuration.stops.firstIndex(where: { $0.id == selected.id }) else { return }
        self.configuration.stops[index].setColor(self.colorWell.color)
        self.gradient.setConfiguration(self.configuration)
        self.save()
    }

    @objc private func addStop() {
        self.gradient.addStop()
    }

    @objc private func removeStop() {
        guard self.gradient.removeSelectedStop() else {
            self.showError("A gradient needs at least two handles")
            NSSound.beep()
            return
        }
    }

    @objc private func reverseScale() {
        self.gradient.reverse()
    }

    @objc private func resetScale() {
        self.configuration = CompactColorScaleStore.shared.reset(self.metric)
        self.gradient.setConfiguration(self.configuration, select: self.configuration.stops.first?.id)
        self.syncAllControls()
        self.showHelp()
    }

    private func syncAllControls() {
        self.mode.selectedSegment = CompactScaleMode.allCases.firstIndex(of: self.configuration.mode) ?? 0
        self.syncFields()
        self.show(stop: self.gradient.selectedStop)
    }

    private func syncFields() {
        self.minimumField.stringValue = self.format(self.configuration.minimum)
        self.maximumField.stringValue = self.format(self.configuration.maximum)
        self.show(stop: self.gradient.selectedStop)
        self.removeButton.isEnabled = self.configuration.stops.count > 2
    }

    private func show(stop: CompactColorStop?) {
        guard let stop else {
            self.valueField.stringValue = ""
            self.colorWell.isEnabled = false
            return
        }
        self.valueField.stringValue = self.format(stop.value)
        self.colorWell.color = stop.color
        self.colorWell.isEnabled = true
    }

    private func save() {
        if CompactColorScaleStore.shared.save(self.configuration, for: self.metric) {
            self.showHelp()
        } else {
            self.showError("The scale could not be saved")
        }
    }

    private func showHelp() {
        self.stateField.textColor = .secondaryLabelColor
        self.stateField.stringValue = "Drag to move · double-click to add · right-click to remove"
    }

    private func showError(_ message: String) {
        self.stateField.textColor = .systemRed
        self.stateField.stringValue = message
    }

    private func number(from field: NSTextField) -> Double? {
        let normalized = field.stringValue
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    private func format(_ value: Double) -> String {
        self.formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

private final class CompactGradientControl: NSView {
    var onSelectionChange: ((CompactColorStop?) -> Void)?
    var onConfigurationChange: ((CompactColorScaleConfiguration) -> Void)?

    private(set) var configuration: CompactColorScaleConfiguration
    private(set) var selectedID: UUID?
    private var draggingID: UUID?
    private let unit: String
    private let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private var trackRect: NSRect {
        NSRect(x: 10, y: 25, width: max(1, self.bounds.width - 20), height: 18)
    }
    private var scale: CompactColorScale {
        CompactColorScale(configuration: self.configuration)
    }
    var selectedStop: CompactColorStop? {
        guard let selectedID else { return nil }
        return self.configuration.stops.first(where: { $0.id == selectedID })
    }

    init(configuration: CompactColorScaleConfiguration, unit: String) {
        self.configuration = configuration
        self.selectedID = configuration.stops.first?.id
        self.unit = unit
        super.init(frame: NSRect(x: 0, y: 0, width: 350, height: 82))
        self.wantsLayer = true
        self.widthAnchor.constraint(equalToConstant: 350).isActive = true
        self.heightAnchor.constraint(equalToConstant: 82).isActive = true
        self.toolTip = "Drag handles. Double-click to add. Right-click a handle to remove."
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = self.trackRect
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).addClip()
        let columns = max(1, Int(track.width.rounded(.up)))
        for column in 0..<columns {
            let position = columns == 1 ? 0 : Double(column) / Double(columns - 1)
            self.scale.color(for: self.scale.value(at: position)).setFill()
            NSBezierPath.fill(NSRect(
                x: track.minX + CGFloat(column),
                y: track.minY,
                width: 1.5,
                height: track.height
            ))
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4)
        border.lineWidth = 1
        border.stroke()

        self.drawRangeLabels()
        for stop in self.sortedStops {
            self.drawHandle(stop)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        if let stop = self.stop(at: point) {
            self.select(stop.id)
            self.draggingID = stop.id
            return
        }
        if event.clickCount >= 2, self.trackRect.insetBy(dx: -3, dy: -8).contains(point) {
            self.addStop(at: self.position(at: point.x))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let draggingID,
              let index = self.configuration.stops.firstIndex(where: { $0.id == draggingID }) else { return }
        let point = self.convert(event.locationInWindow, from: nil)
        let value = self.scale.value(at: self.position(at: point.x))
        self.configuration.stops[index].value = (value * 100).rounded() / 100
        self.needsDisplay = true
        self.onSelectionChange?(self.configuration.stops[index])
        self.onConfigurationChange?(self.configuration)
    }

    override func mouseUp(with event: NSEvent) {
        self.draggingID = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        guard let stop = self.stop(at: point) else {
            super.rightMouseDown(with: event)
            return
        }
        self.select(stop.id)
        _ = self.removeSelectedStop()
    }

    func setConfiguration(_ configuration: CompactColorScaleConfiguration, select id: UUID? = nil) {
        self.configuration = configuration
        if let id, configuration.stops.contains(where: { $0.id == id }) {
            self.selectedID = id
        } else if let selectedID, configuration.stops.contains(where: { $0.id == selectedID }) {
            self.selectedID = selectedID
        } else {
            self.selectedID = configuration.stops.first?.id
        }
        self.needsDisplay = true
        self.onSelectionChange?(self.selectedStop)
    }

    func addStop() {
        let positions = self.sortedStops.map { self.scale.position(for: $0.value) }
        let edges = [0.0] + positions + [1.0]
        var largest = (start: 0.0, end: 0.0)
        for index in 0..<(edges.count - 1) where edges[index + 1] - edges[index] > largest.end - largest.start {
            largest = (edges[index], edges[index + 1])
        }
        self.addStop(at: (largest.start + largest.end) / 2)
    }

    @discardableResult
    func removeSelectedStop() -> Bool {
        guard self.configuration.stops.count > 2, let selectedID,
              let index = self.configuration.stops.firstIndex(where: { $0.id == selectedID }) else { return false }
        let removedValue = self.configuration.stops[index].value
        self.configuration.stops.remove(at: index)
        self.selectedID = self.configuration.stops.min(by: {
            abs($0.value - removedValue) < abs($1.value - removedValue)
        })?.id
        self.needsDisplay = true
        self.onSelectionChange?(self.selectedStop)
        self.onConfigurationChange?(self.configuration)
        return true
    }

    func reverse() {
        let sum = self.configuration.minimum + self.configuration.maximum
        self.configuration.stops = self.configuration.stops.map { stop in
            var copy = stop
            copy.value = sum - copy.value
            return copy
        }
        self.needsDisplay = true
        self.onSelectionChange?(self.selectedStop)
        self.onConfigurationChange?(self.configuration)
    }

    private var sortedStops: [CompactColorStop] {
        self.configuration.stops.enumerated().sorted { lhs, rhs in
            lhs.element.value == rhs.element.value ? lhs.offset < rhs.offset : lhs.element.value < rhs.element.value
        }.map(\.element)
    }

    private func addStop(at position: Double) {
        let value = self.scale.value(at: position)
        let stop = CompactColorStop(value: (value * 100).rounded() / 100, color: self.scale.color(for: value))
        self.configuration.stops.append(stop)
        self.selectedID = stop.id
        self.needsDisplay = true
        self.onSelectionChange?(stop)
        self.onConfigurationChange?(self.configuration)
    }

    private func select(_ id: UUID) {
        self.selectedID = id
        self.needsDisplay = true
        self.onSelectionChange?(self.selectedStop)
    }

    private func stop(at point: NSPoint) -> CompactColorStop? {
        self.configuration.stops.reversed().first { stop in
            let x = self.x(for: stop.value)
            return abs(point.x - x) <= 9 && point.y >= self.trackRect.maxY - 4 && point.y <= self.bounds.maxY
        }
    }

    private func position(at x: CGFloat) -> Double {
        Double(min(1, max(0, (x - self.trackRect.minX) / self.trackRect.width)))
    }

    private func x(for value: Double) -> CGFloat {
        self.trackRect.minX + (CGFloat(self.scale.position(for: value)) * self.trackRect.width)
    }

    private func drawHandle(_ stop: CompactColorStop) {
        let x = self.x(for: stop.value)
        let selected = stop.id == self.selectedID
        let circle = NSRect(x: x - 6, y: self.trackRect.maxY + 4, width: 12, height: 12)

        stop.color.setFill()
        let path = NSBezierPath(ovalIn: circle)
        path.fill()
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()

        let label = self.format(stop.value)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: selected ? .semibold : .regular),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        NSAttributedString(string: label, attributes: attributes).draw(
            in: NSRect(x: x - 30, y: circle.maxY + 1, width: 60, height: 11)
        )
    }

    private func drawRangeLabels() {
        let paragraph = NSMutableParagraphStyle()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph
        ]
        paragraph.alignment = .left
        NSAttributedString(
            string: "\(self.format(self.configuration.minimum)) \(self.unit)",
            attributes: attributes
        ).draw(in: NSRect(x: self.trackRect.minX, y: 4, width: 100, height: 11))

        paragraph.alignment = .right
        NSAttributedString(
            string: "\(self.format(self.configuration.maximum)) \(self.unit)",
            attributes: attributes
        ).draw(in: NSRect(x: self.trackRect.maxX - 100, y: 4, width: 100, height: 11))
    }

    private func format(_ value: Double) -> String {
        self.formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
