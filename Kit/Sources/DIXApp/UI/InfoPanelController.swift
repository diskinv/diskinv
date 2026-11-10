//
//  InfoPanelController.swift
//  DIXApp
//
//  The Information panel (InfoPanel.nib / NTInfoView in the original): a small
//  utility panel with the selected item's icon and name, then Name, Kind, Size,
//  Modified, Created, Owner, Group, Permission, Version and Path.
//
//  GPL v3
//

import AppKit
import DIXCore
import UniformTypeIdentifiers

final class InfoPanelController: NSObject {
    static let shared = InfoPanelController()

    let panel: NSPanel
    private let icon = NSImageView(frame: NSRect(x: 7, y: 202, width: 48, height: 48))
    private let nameField = NSTextField(labelWithString: "")
    private let infoView = InfoPairsView(frame: NSRect(x: 0, y: 0, width: 228, height: 200))
    private let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 228, height: 200))
    private var shown: (path: String, size: UInt64)?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 228, height: 260),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        super.init()
        panel.title = "Information"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.minSize = NSSize(width: 150, height: 206)
        panel.isFloatingPanel = true
        panel.setFrameAutosaveName("InfoPanel")
        let content = panel.contentView!
        icon.autoresizingMask = [.minYMargin]
        icon.imageScaling = .scaleProportionallyUpOrDown
        nameField.frame = NSRect(x: 60, y: 215, width: 160, height: 22)
        nameField.autoresizingMask = [.width, .minYMargin]
        nameField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        nameField.lineBreakMode = .byTruncatingMiddle
        scroll.documentView = infoView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        for v in [icon, nameField, scroll] as [NSView] { content.addSubview(v) }
        if panel.frame.origin == .zero, let screen = NSScreen.main {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 260, y: screen.visibleFrame.maxY - 40))
        }
    }

    var isVisible: Bool { panel.isVisible }

    func hide() { panel.orderOut(nil) }

    /// shows the panel with an item (or empty)
    func show(_ item: (model: DocumentModel, node: NodeIndex)?) {
        update(item)
        panel.orderFront(nil)
    }

    func update(_ item: (model: DocumentModel, node: NodeIndex)?) {
        guard let (model, node) = item else {
            shown = nil
            nameField.stringValue = ""
            icon.image = nil
            infoView.pairs = []
            return
        }
        let s = model.snapshot
        let path = s.path(of: node)
        let size = model.size(of: node)
        if let shown, shown.path == path, shown.size == size { return }
        shown = (path, size)
        nameField.stringValue = FileManager.default.fileExists(atPath: path) ? FileManager.default.displayName(atPath: path) : s.name(of: node)
        icon.image = FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: UTType(s.kind(of: node).identifier) ?? .data)
        infoView.pairs = Self.pairs(for: node, model: model)
        infoView.frame.size.width = scroll.contentSize.width
        infoView.sizeToFitPairs()
    }

    static func pairs(for node: NodeIndex, model: DocumentModel) -> [(String, String)] {
        let s = model.snapshot
        let path = s.path(of: node)
        let flags = s.flags[node]
        var pairs: [(String, String)] = []
        pairs.append(("Name:", s.name(of: node)))
        let kind = flags.contains(.directory) && !flags.contains(.package) ? "Folder" : s.kind(of: node).name
        pairs.append(("Kind:", kind))
        pairs.append(("Size:", "\(Format.size(s.allocatedSize[node])) on disk (\(Format.count(Int(clamping: s.logicalSize[node]))) bytes)"))
        if flags.contains(.directory) {
            pairs.append(("Items:", Format.count(DocumentWindowController.itemCount(s, node))))
        }
        if flags.contains(.cloudPlaceholder) {
            pairs.append(("Where:", HoverText.cloudNote(path: path, sizeMode: .allocated, logical: s.logicalSize[node]).capitalizingFirst))
        }
        if flags.contains(.hardLinkDuplicate) { pairs.append(("Hard link:", "counted once, at another link")) }
        if flags.contains(.unreadable) { pairs.append(("Note:", "couldn’t be read")) }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            if let d = attrs[.modificationDate] as? Date { pairs.append(("Modified:", df.string(from: d))) }
            if let d = attrs[.creationDate] as? Date { pairs.append(("Created:", df.string(from: d))) }
            if let o = attrs[.ownerAccountName] as? String { pairs.append(("Owner:", o)) }
            if let g = attrs[.groupOwnerAccountName] as? String { pairs.append(("Group:", g)) }
            if let p = attrs[.posixPermissions] as? Int { pairs.append(("Permission:", permissionString(p, directory: flags.contains(.directory)))) }
        } else {
            pairs.append(("Scanned:", DateFormatter.localizedString(from: s.scanDate, dateStyle: .medium, timeStyle: .short)))
        }
        if flags.contains(.package), let version = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String {
            pairs.append(("Version:", version))
        }
        pairs.append(("Path:", path))
        if flags.contains(.symlink), let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            pairs.append(("Resolved:", dest))
        }
        if !flags.contains(.directory) || flags.contains(.package),
           let app = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path)), !flags.contains(.package) {
            pairs.append(("Application:", FileManager.default.displayName(atPath: app.path)))
        }
        return pairs
    }

    static func permissionString(_ mode: Int, directory: Bool) -> String {
        var s = directory ? "d" : "-"
        for shift in [6, 3, 0] {
            let bits = (mode >> shift) & 7
            s += (bits & 4 != 0 ? "r" : "-") + (bits & 2 != 0 ? "w" : "-") + (bits & 1 != 0 ? "x" : "-")
        }
        return s
    }
}

/// Title/value pairs: titles right-aligned in grey, values wrapping (NTTitledInfoView).
final class InfoPairsView: NSView {
    var pairs: [(String, String)] = [] { didSet { rebuild() } }
    private var fields: [(NSTextField, NSTextField)] = []
    override var isFlipped: Bool { true }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        fields = pairs.map { title, value in
            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            t.textColor = .secondaryLabelColor
            t.alignment = .right
            let v = NSTextField(wrappingLabelWithString: value)
            v.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            v.isSelectable = true
            addSubview(t)
            addSubview(v)
            return (t, v)
        }
        sizeToFitPairs()
    }

    func sizeToFitPairs() {
        let titleWidth: CGFloat = 72
        var y: CGFloat = 4
        let valueWidth = max(40, bounds.width - titleWidth - 14)
        for (t, v) in fields {
            let h = max(14, v.sizeThatFits(NSSize(width: valueWidth, height: 1000)).height)
            t.frame = NSRect(x: 4, y: y, width: titleWidth, height: 14)
            v.frame = NSRect(x: titleWidth + 8, y: y, width: valueWidth, height: h)
            y += h + 3
        }
        setFrameSize(NSSize(width: bounds.width, height: y + 4))
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if oldSize.width != bounds.width { sizeToFitPairs() }
    }
}
