//
//  PreferencesWindowController.swift
//  DIXApp
//
//  Preferences: the defaults new windows start with (the original's General
//  and Treemap panes; each window's View menu changes its own copy).
//
//  GPL v3
//

import AppKit

final class PreferencesWindowController: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Preferences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        _ = ViewOptions.fromDefaults()   // registers the defaults
        func check(_ title: String, _ key: String) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values." + key, options: nil)
            return b
        }
        func header(_ title: String, _ image: String) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let icon = NSImageView(image: AppResources.image(image) ?? NSImage())
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let row = NSStackView(views: [icon, label])
            row.spacing = 6
            return row
        }
        let stack = NSStackView(views: [
            header("General", "GeneralPreferences"),
            check("Show physical file size (space on disk)", ViewOptions.physicalSizeKey),
            check("Show package contents", ViewOptions.packageContentsKey),
            check("Split windows horizontally", "SplitWindowHorizontally"),
            header("Treemap", "TreeMapPreferences"),
            check("Show free space", ViewOptions.freeSpaceKey),
            check("Show other space", ViewOptions.otherSpaceKey),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        for v in stack.arrangedSubviews where v is NSButton {
            stack.setCustomSpacing(6, after: v)
            v.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 54).isActive = true
        }
        window.contentView = stack
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
