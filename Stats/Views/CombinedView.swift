//
//  CombinedView.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 09/01/2023
//  Using Swift 5.0
//  Running on macOS 13.1
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class CombinedView: NSObject, NSGestureRecognizerDelegate {
    private var menuBarItem: NSStatusItem? = nil
    private var view: CompactSystemView = CompactSystemView()
    private var popup: PopupWindow? = nil
    
    private var status: Bool {
        Store.shared.bool(key: "CombinedModules", defaultValue: true)
    }
    
    private var activeModules: [Module] {
        modules.filter({ $0.enabled }).sorted(by: { $0.combinedPosition < $1.combinedPosition })
    }
    
    private var combinedModulesPopup: Bool {
        get { Store.shared.bool(key: "CombinedModules_popup", defaultValue: true) }
        set { Store.shared.set(key: "CombinedModules_popup", value: newValue) }
    }
    
    override init() {
        super.init()
        
        modules.forEach { (m: Module) in
            m.menuBar.callback = { [weak self] in
                if let s = self?.status, s {
                    DispatchQueue.main.async(execute: {
                        self?.recalculate()
                    })
                }
            }
        }
        
        self.popup = PopupWindow(title: "Combined modules", module: .combined, view: Popup()) { _ in }

        self.view.widthCallback = { [weak self] width in
            self?.menuBarItem?.length = width
        }
        
        if self.status {
            self.enable()
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(listenForOneView), name: .toggleOneView, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForModuleRearrrange), name: .moduleRearrange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForCPUUsage), name: .compactCPUUsage, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForRAMUsage), name: .compactRAMUsage, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForDiskFree), name: .compactDiskFree, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    public func enable() {
        self.menuBarItem = NSStatusBar.system.statusItem(withLength: 0)
        DispatchQueue.main.async(execute: {
            self.menuBarItem?.autosaveName = "CombinedModules"
        })
        self.menuBarItem?.button?.addSubview(self.view)
        self.menuBarItem?.button?.image = NSImage()
        self.menuBarItem?.button?.toolTip = localizedString("Combined modules")
        
        self.menuBarItem?.button?.target = self
        self.menuBarItem?.button?.action = #selector(self.handleClick)
        self.menuBarItem?.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        
        DispatchQueue.main.async(execute: {
            self.recalculate()
        })
    }
    
    public func disable() {
        if let item = self.menuBarItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        self.menuBarItem = nil
    }
    
    private func recalculate() {
        self.view.recalculateWidth()
    }
    
    // call when popup appear/disappear
    private func visibilityCallback(_ state: Bool) {}
    
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
        let moduleName = self.view.module(at: location)
        guard let module = self.activeModules.first(where: { $0.name == moduleName }) else { return }
        
        var userInfo: [String: Any] = [
            "module": module.name,
            "origin": window.frame.origin,
            "center": window.frame.width/2
        ]
        let widgets = module.menuBar.activeWidgets
        if let widget = widgets.first {
            userInfo["widget"] = widget.type
        }
        NotificationCenter.default.post(name: .togglePopup, object: nil, userInfo: userInfo)
    }
    
    private func togglePopup() {
        guard let popup = self.popup, let item = self.menuBarItem, let window = item.button?.window else { return }
        let openedWindows = NSApplication.shared.windows.filter{ $0 is NSPanel }
        openedWindows.forEach{ $0.setIsVisible(false) }
        
        if popup.occlusionState.rawValue == 8192 {
            NSApplication.shared.activate(ignoringOtherApps: true)
            
            popup.contentView?.invalidateIntrinsicContentSize()
            
            let windowCenter = popup.contentView!.intrinsicContentSize.width / 2
            var x = window.frame.origin.x - windowCenter + window.frame.width/2
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
    
    @objc private func listenForModuleRearrrange() {
        self.recalculate()
    }

    @objc private func listenForCPUUsage(_ notification: Notification) {
        guard let value = notification.object as? Double else { return }
        self.view.setCPU(value)
    }

    @objc private func listenForRAMUsage(_ notification: Notification) {
        guard let value = notification.object as? [String: Double],
              let usage = value["usage"], let swap = value["swap"] else { return }
        self.view.setRAM(usage, swap: swap)
    }

    @objc private func listenForDiskFree(_ notification: Notification) {
        guard let value = notification.object as? Int64 else { return }
        self.view.setDiskFree(value)
    }
}

private class CompactSystemView: NSView {
    fileprivate var widthCallback: ((CGFloat) -> Void)?

    private let horizontalPadding: CGFloat = 4
    private let columnSpacing: CGFloat = 7
    private let labelValueSpacing: CGFloat = 2
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
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

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: Constants.Widget.height))
        self.recalculateWidth()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    fileprivate func setCPU(_ value: Double) {
        DispatchQueue.main.async {
            self.cpu = value
            self.refresh()
        }
    }

    fileprivate func setRAM(_ value: Double, swap: Double) {
        DispatchQueue.main.async {
            self.ram = value
            self.swap = swap
            self.refresh()
        }
    }

    fileprivate func setDiskFree(_ value: Int64) {
        DispatchQueue.main.async {
            self.diskFree = value
            self.refresh()
        }
    }

    fileprivate func recalculateWidth() {
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
    }

    fileprivate func module(at point: NSPoint) -> String {
        let firstColumnMaxX = self.horizontalPadding + self.firstColumnWidth + (self.columnSpacing / 2)
        if point.x <= firstColumnMaxX {
            return point.y >= self.bounds.midY ? "CPU" : "RAM"
        }
        return point.y >= self.bounds.midY ? "Disk" : "RAM"
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let firstX = self.horizontalPadding
        let secondX = firstX + self.firstColumnWidth + self.columnSpacing
        self.draw(label: self.cpuLabel, value: self.cpuValue, x: firstX, labelWidth: self.firstLabelWidth, valueWidth: self.firstValueWidth, top: true)
        self.draw(label: self.ramLabel, value: self.ramValue, x: firstX, labelWidth: self.firstLabelWidth, valueWidth: self.firstValueWidth, top: false)
        self.draw(label: self.diskFreeLabel, value: self.diskFreeValue, x: secondX, labelWidth: self.secondLabelWidth, valueWidth: self.secondValueWidth, top: true)
        self.draw(label: self.swapLabel, value: self.swapValue, x: secondX, labelWidth: self.secondLabelWidth, valueWidth: self.secondValueWidth, top: false)
    }

    private func refresh() {
        self.recalculateWidth()
        self.needsDisplay = true
    }

    private func draw(label: String, value: String, x: CGFloat, labelWidth: CGFloat, valueWidth: CGFloat, top: Bool) {
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
        self.draw(label, in: labelRect, alignment: .center)
        self.draw(value, in: valueRect, alignment: .right)
    }

    private func draw(_ text: String, in rect: NSRect, alignment: NSTextAlignment) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        NSAttributedString(string: text, attributes: [
            .font: self.font,
            .foregroundColor: NSColor.textColor,
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
        return "\(self.gigabytes(Double(value))) GB"
    }

    private var swapValue: String {
        guard let value = self.swap else { return "-- GB" }
        return "\(self.gigabytes(value)) GB"
    }

    private func significant(_ value: Double) -> String {
        self.numberFormatter.string(from: NSNumber(value: max(0, value))) ?? "0"
    }

    private func percentage(_ value: Double) -> String {
        self.significant(min(100, max(0, value * 100)))
    }

    private func gigabytes(_ bytes: Double) -> String {
        let value = max(0, bytes / 1_073_741_824)
        if (value * 10).rounded() / 10 < 10 {
            return self.smallGigabytesFormatter.string(from: NSNumber(value: value)) ?? "0.0"
        }
        return self.significant(value)
    }
}

private class Popup: NSStackView, Popup_p {
    fileprivate var keyboardShortcut: [UInt16] = []
    fileprivate var sizeCallback: ((NSSize) -> Void)? = nil
    
    init() {
        self.keyboardShortcut = Store.shared.array(key: "CombinedModules_popup_keyboardShortcut", defaultValue: []) as? [UInt16] ?? []
        
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))
        
        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = Constants.Popup.spacing*3
        
        self.reinit()
        
        NotificationCenter.default.addObserver(self, selector: #selector(reinit), name: .toggleModule, object: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: .toggleOneView, object: nil)
    }
    
    fileprivate func settings() -> NSView? { return nil }
    fileprivate func appear() {}
    fileprivate func disappear() {}
    fileprivate func setKeyboardShortcut(_ binding: [UInt16]) {
        self.keyboardShortcut = binding
        Store.shared.set(key: "CombinedModules_popup_keyboardShortcut", value: binding)
    }
    
    @objc private func reinit() {
        self.subviews.forEach({ $0.removeFromSuperview() })
        
        let availableModules = modules.filter({ $0.enabled && $0.portal != nil })
        var modulesHeight: CGFloat = 0
        availableModules.forEach { (m: Module) in
            if let p = m.portal {
                modulesHeight += p.height
                self.addArrangedSubview(p)
            }
        }
        
        let h = modulesHeight + (CGFloat(availableModules.count-1)*self.spacing)
        if h > 0 {
            self.setFrameSize(NSSize(width: self.frame.width, height: h))
            self.sizeCallback?(self.frame.size)
        }
    }
}
