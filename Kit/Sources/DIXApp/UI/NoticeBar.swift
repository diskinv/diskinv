//
//  NoticeBar.swift
//  DIXApp
//
//  A non-blocking note at the top of the document window, e.g. "12 folders
//  couldn't be read" with a button to the Full Disk Access settings, or "Saved
//  scan from ..." with Refresh. Dismissed with its close button.
//
//  GPL v3
//

import AppKit

final class NoticeBar: NSView {
    private let box = NSBox()
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let close = NSButton()
    private var handler: (() -> Void)?
    var onDismiss: (() -> Void)?

    static let height: CGFloat = 34

    override init(frame: NSRect) {
        super.init(frame: frame)
        box.boxType = .custom
        box.cornerRadius = 6
        box.borderWidth = 1
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        box.autoresizingMask = [.width, .height]
        addSubview(box)
        icon.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = self
        button.action = #selector(buttonPressed(_:))
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        close.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(dismiss(_:))
        close.setAccessibilityLabel("Dismiss")
        for v in [icon, label, button, close] as [NSView] { addSubview(v) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Notice")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    enum Style { case warning, info }

    func show(_ text: String, style: Style, buttonTitle: String?, action: (() -> Void)?) {
        label.stringValue = text
        handler = action
        button.title = buttonTitle ?? ""
        button.isHidden = buttonTitle == nil
        let tint: NSColor = style == .warning ? .systemYellow : .systemBlue
        box.fillColor = tint.withAlphaComponent(0.13)
        box.borderColor = tint.withAlphaComponent(0.45)
        icon.image = NSImage(systemSymbolName: style == .warning ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath",
                             accessibilityDescription: nil)
        icon.contentTintColor = style == .warning ? .systemYellow : .systemBlue
        isHidden = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        box.frame = bounds
        let h = bounds.height
        icon.frame = NSRect(x: 10, y: (h - 16) / 2, width: 16, height: 16)
        close.frame = NSRect(x: bounds.width - 26, y: (h - 18) / 2, width: 18, height: 18)
        var right = close.frame.minX - 6
        if !button.isHidden {
            button.sizeToFit()
            let bw = button.frame.width + 8
            button.frame = NSRect(x: right - bw, y: (h - 22) / 2, width: bw, height: 22)
            right = button.frame.minX - 8
        }
        label.frame = NSRect(x: 34, y: 2, width: max(0, right - 34), height: h - 4)
        // center one or two lines vertically
        let fit = label.sizeThatFits(NSSize(width: label.frame.width, height: h)).height
        label.frame.origin.y = max(1, (h - min(fit, h - 2)) / 2)
        label.frame.size.height = min(fit, h - 2)
    }

    @objc private func buttonPressed(_ sender: Any?) { handler?() }

    @objc private func dismiss(_ sender: Any?) {
        isHidden = true
        onDismiss?()
    }

    var text: String { label.stringValue }
}
