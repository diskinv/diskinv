//
//  DrivesPanelController.swift
//  DIXApp
//
//  The drives panel shown at launch (VolumesPanel.nib, DrivesPanelController):
//  the mounted volumes with icon, name and format, capacity/used/free, and a
//  usage bar scaled to the largest volume. Double-click or Open Volume scans
//  one; "Select Folder: …" opens a folder or a saved scan.
//
//  GPL v3
//

import AppKit

struct VolumeEntry {
    var url: URL
    var name: String
    var format: String
    var icon: NSImage
    var capacity: UInt64?
    var available: UInt64?

    var used: UInt64? {
        guard let c = capacity, let a = available else { return nil }
        return c > a ? c - a : 0
    }
}

final class DrivesPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = DrivesPanelController()

    let window: NSWindow
    let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 490, height: 165))
    private let scroll = NSScrollView(frame: NSRect(x: 20, y: 76, width: 492, height: 167))
    let openButton = NSButton(title: "Open Volume", target: nil, action: nil)
    private(set) var volumes: [VolumeEntry] = []
    private var maxCapacity: UInt64 = 0

    static let iconColumn = NSUserInterfaceItemIdentifier("icon")
    static let volumeColumn = NSUserInterfaceItemIdentifier("volume")
    static let usageColumn = NSUserInterfaceItemIdentifier("usage")
    static let barColumn = NSUserInterfaceItemIdentifier("usagePercent")

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 532, height: 263),
                          styleMask: [.titled, .miniaturizable, .resizable], backing: .buffered, defer: true)
        super.init()
        window.title = ""
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 502, height: 130)
        window.tabbingMode = .disallowed
        let content = window.contentView!

        func column(_ id: NSUserInterfaceItemIdentifier, _ width: CGFloat) -> NSTableColumn {
            let c = NSTableColumn(identifier: id)
            c.width = width
            c.minWidth = 4
            c.resizingMask = .autoresizingMask
            c.isEditable = false
            return c
        }
        tableView.addTableColumn(column(Self.iconColumn, 50))
        tableView.addTableColumn(column(Self.volumeColumn, 147))
        tableView.addTableColumn(column(Self.usageColumn, 126))
        tableView.addTableColumn(column(Self.barColumn, 155))
        tableView.headerView = nil
        tableView.rowHeight = 45
        tableView.intercellSpacing = NSSize(width: 3, height: 2)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openVolume(_:))
        tableView.setAccessibilityLabel("Volumes")
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)

        openButton.frame = NSRect(x: 336, y: 20, width: 152, height: 32)
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.autoresizingMask = [.minXMargin, .maxYMargin]
        openButton.target = self
        openButton.action = #selector(openVolume(_:))
        openButton.isEnabled = false
        content.addSubview(openButton)

        let box = NSBox(frame: NSRect(x: 17, y: 16, width: 216, height: 42))
        box.titlePosition = .noTitle
        box.autoresizingMask = [.maxXMargin, .maxYMargin]
        let label = NSTextField(labelWithString: "Select Folder:")
        label.frame = NSRect(x: 17, y: 11, width: 118, height: 17)
        let choose = NSButton(title: "...", target: nil, action: #selector(NSDocumentController.openDocument(_:)))
        choose.bezelStyle = .rounded
        choose.frame = NSRect(x: 134, y: 3, width: 66, height: 32)
        choose.toolTip = "Choose a folder to scan, or a saved scan to open"
        box.contentView?.addSubview(label)
        box.contentView?.addSubview(choose)
        content.addSubview(box)

        window.setFrameAutosaveName("DrivesPlanel")
        if !window.setFrameUsingName("DrivesPlanel") { window.center() }
        window.initialFirstResponder = tableView

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            ws.addObserver(self, selector: #selector(volumesChanged(_:)), name: name, object: nil)
        }
        reloadVolumes()
    }

    func show() { window.makeKeyAndOrderFront(nil) }

    @objc private func volumesChanged(_ n: Notification) { reloadVolumes() }

    func reloadVolumes() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeSupportsVolumeSizesKey, .volumeLocalizedFormatDescriptionKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        setVolumes(urls.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            let sizes = v?.volumeSupportsVolumeSizes ?? true
            return VolumeEntry(url: url, name: v?.volumeLocalizedName ?? FileManager.default.displayName(atPath: url.path),
                               format: v?.volumeLocalizedFormatDescription ?? "", icon: icon,
                               capacity: sizes ? (v?.volumeTotalCapacity).map { UInt64($0) } : nil,
                               available: sizes ? (v?.volumeAvailableCapacity).map { UInt64($0) } : nil)
        })
    }

    func setVolumes(_ entries: [VolumeEntry]) {
        volumes = entries
        maxCapacity = entries.compactMap(\.capacity).max() ?? 0
        tableView.reloadData()
        openButton.isEnabled = tableView.selectedRow >= 0
    }

    @objc func openVolume(_ sender: Any?) {
        let rows = tableView.selectedRowIndexes
        for row in rows where row < volumes.count {
            let url = volumes[row].url
            // next run loop turn, so the button doesn't stay pressed while the scan starts
            DispatchQueue.main.async {
                (NSDocumentController.shared as? DocumentController)?.scanFolder(url)
            }
        }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { volumes.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        openButton.isEnabled = tableView.selectedRow >= 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, row < volumes.count else { return nil }
        let v = volumes[row]
        switch id {
        case Self.iconColumn:
            let image = NSImageView(image: v.icon)
            image.imageScaling = .scaleProportionallyDown
            return image
        case Self.volumeColumn:
            let text = NSMutableAttributedString(string: v.name, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
            if !v.format.isEmpty {
                text.append(NSAttributedString(string: "\n " + v.format,
                                               attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                            .foregroundColor: NSColor.secondaryLabelColor]))
            }
            return Self.centered(text)
        case Self.usageColumn:
            let right = NSMutableParagraphStyle()
            right.alignment = .right
            let cap = v.capacity.map(Format.size) ?? "n/a", used = v.used.map(Format.size) ?? "n/a"
            let free = v.available.map(Format.size) ?? "n/a"
            let text = NSMutableAttributedString(string: "Capacity: \(cap)", attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize), .paragraphStyle: right])
            text.append(NSAttributedString(string: "\nUsed: \(used)\nFree: \(free)", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .paragraphStyle: right]))
            return Self.centered(text)
        default:
            let container = NSView()
            guard let cap = v.capacity, let used = v.used, maxCapacity > 0 else { return container }
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = Double(cap)
            bar.doubleValue = Double(used)
            bar.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(bar)
            // each volume at least 20% wide, else too narrow to see
            let fraction = max(Double(cap) / Double(maxCapacity), 0.2)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                bar.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                bar.heightAnchor.constraint(equalToConstant: 18),
                bar.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: CGFloat(fraction), constant: -32 * CGFloat(fraction)),
            ])
            return container
        }
    }

    /// a multi-line label centered vertically in the 45-point row
    private static func centered(_ text: NSAttributedString) -> NSView {
        let container = NSView()
        let field = NSTextField(labelWithAttributedString: text)
        field.maximumNumberOfLines = 3
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
}
