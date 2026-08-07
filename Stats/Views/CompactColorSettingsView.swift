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

        let rows = CompactMetric.allCases.map { metric in
            PreferencesRow(metric.title, "Displayed in \(metric.unit)", component: CompactScaleEditorView(metric: metric))
        }
        self.addArrangedSubview(PreferencesSection(
            title: "Compact colors",
            subtitle: "White → yellow → orange → red → violet",
            rows
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class CompactScaleEditorView: NSStackView, NSTextFieldDelegate {
    private let metric: CompactMetric
    private var fields: [NSTextField] = []
    private let stateField = NSTextField(labelWithString: "")
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
        super.init(frame: .zero)

        self.orientation = .vertical
        self.alignment = .trailing
        self.spacing = 3

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .bottom
        controls.spacing = 4

        let names = ["W", "Y", "O", "R", "V"]
        for (index, value) in CompactColorScaleStore.shared.thresholds(for: metric).enumerated() {
            let field = NSTextField(string: self.format(value))
            field.alignment = .right
            field.controlSize = .small
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 42).isActive = true
            field.toolTip = ["White", "Yellow", "Orange", "Red", "Violet"][index]
            self.fields.append(field)

            let label = NSTextField(labelWithString: names[index])
            label.alignment = .center
            label.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            label.textColor = index == 0 ? .labelColor : CompactColorScale.colors[index]
            label.toolTip = field.toolTip

            let stop = NSStackView(views: [label, field])
            stop.orientation = .vertical
            stop.alignment = .centerX
            stop.spacing = 1
            controls.addArrangedSubview(stop)
        }

        let unit = NSTextField(labelWithString: metric.unit)
        unit.font = NSFont.systemFont(ofSize: 10)
        unit.textColor = .secondaryLabelColor
        unit.widthAnchor.constraint(equalToConstant: 20).isActive = true
        controls.addArrangedSubview(unit)

        let reverse = NSButton(title: "Reverse", target: self, action: #selector(self.reverseScale))
        reverse.controlSize = .small
        reverse.bezelStyle = .rounded
        controls.addArrangedSubview(reverse)

        self.stateField.font = NSFont.systemFont(ofSize: 10)
        self.stateField.lineBreakMode = .byTruncatingTail
        self.stateField.maximumNumberOfLines = 1

        self.addArrangedSubview(controls)
        self.addArrangedSubview(self.stateField)
        self.validateAndSave(postChange: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func controlTextDidChange(_ obj: Notification) {
        self.validateAndSave(postChange: true)
    }

    @objc private func reverseScale() {
        guard let values = self.values(), CompactColorScale.direction(of: values) != nil else {
            self.showError("Values must be strictly monotone")
            NSSound.beep()
            return
        }

        let reversed = Array(values.reversed())
        for (field, value) in zip(self.fields, reversed) {
            field.stringValue = self.format(value)
        }
        self.validateAndSave(postChange: true)
    }

    private func validateAndSave(postChange: Bool) {
        guard let values = self.values() else {
            self.showError("Enter five numeric values")
            return
        }
        guard let direction = CompactColorScale.direction(of: values) else {
            self.showError("Values must be strictly monotone")
            return
        }

        self.stateField.textColor = .secondaryLabelColor
        self.stateField.stringValue = direction == .increasing ? "Increasing scale" : "Decreasing scale"
        if postChange {
            CompactColorScaleStore.shared.save(values, for: self.metric)
        }
    }

    private func values() -> [Double]? {
        let values = self.fields.compactMap { field -> Double? in
            let normalized = field.stringValue
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: ",", with: ".")
            return Double(normalized)
        }
        return values.count == self.fields.count ? values : nil
    }

    private func showError(_ message: String) {
        self.stateField.textColor = .systemRed
        self.stateField.stringValue = message
    }

    private func format(_ value: Double) -> String {
        self.formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
