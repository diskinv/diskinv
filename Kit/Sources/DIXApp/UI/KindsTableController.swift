//
//  KindsTableController.swift
//  DIXApp
//
//  The file kind statistics (the original's kinds drawer, FileKindsTableController):
//  Color (a cushion swatch, as in the treemap), Kind, Size, Files. Sorted by
//  size; the columns sort. Selecting a file elsewhere selects its kind here;
//  selecting a kind here highlights its files in the treemap.
//
//  GPL v3
//

import AppKit
import DIXCore
import DIXTreemap

final class KindsTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
    private let model: DocumentModel
    private var observer = 0
    private var rows: [KindStatistic] = []
    private var swatches: [String: NSImage] = [:]
    private var syncing = false
    /// "Show Files in Selection List" (context menu)
    var onShowFilesOfKind: ((String) -> Void)?

    static let colorColumn = NSUserInterfaceItemIdentifier("color")
    static let kindColumn = NSUserInterfaceItemIdentifier("kindName")
    static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    static let countColumn = NSUserInterfaceItemIdentifier("fileCount")

    init(model: DocumentModel) {
        self.model = model
        super.init()
        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, _ width: CGFloat, right: Bool = false,
                    sortKey: String?, ascending: Bool = true) -> NSTableColumn {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = 20
            c.maxWidth = 1000
            if right { c.headerCell.alignment = .right }
            if let sortKey { c.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: ascending) }
            c.resizingMask = [.autoresizingMask, .userResizingMask]
            return c
        }
        tableView.addTableColumn(column(Self.colorColumn, "Color", 36, sortKey: nil))
        tableView.addTableColumn(column(Self.kindColumn, "Kind", 128, sortKey: "kindName"))
        tableView.addTableColumn(column(Self.sizeColumn, "Size", 68, right: true, sortKey: "size", ascending: false))
        tableView.addTableColumn(column(Self.countColumn, "Files", 56, right: true, sortKey: "fileCount", ascending: false))
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.intercellSpacing = NSSize(width: 3, height: 2)
        tableView.rowHeight = 17
        tableView.style = .plain
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 300, height: 25))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        tableView.target = self
        tableView.action = #selector(clicked(_:))
        tableView.setAccessibilityLabel("File kinds")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Files in Selection List", action: #selector(showFilesInSelectionList(_:)), keyEquivalent: "").target = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        observer = model.observe { [weak self] change in self?.modelChanged(change) }
        reload()
    }

    deinit { model.removeObserver(observer) }

    var statistics: [KindStatistic] { rows }

    func reload() {
        swatches.removeAll()
        rows = model.kindStatistics.entries
        sortRows()
        syncing = true
        tableView.reloadData()
        syncing = false
        syncSelection()
    }

    private func sortRows() {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        let asc = d.ascending
        rows.sort { a, b in
            switch key {
            case "kindName":
                let r = a.name.compare(b.name, options: [.caseInsensitive, .numeric])
                return asc ? r == .orderedAscending : r == .orderedDescending
            case "fileCount":
                return a.fileCount != b.fileCount ? (asc ? a.fileCount < b.fileCount : a.fileCount > b.fileCount) : a.size > b.size
            default:
                return a.size != b.size ? (asc ? a.size < b.size : a.size > b.size) : a.name < b.name
            }
        }
    }

    private func modelChanged(_ change: DocumentModel.Change) {
        switch change {
        case .snapshot, .options: reload()
        case .selection: syncSelection()
        case .highlight:
            if !syncing { syncSelection(preferHighlight: true) }
        case .zoom: break
        }
    }

    /// select the selected file's kind (folders: no kind, unless one is highlighted)
    private func syncSelection(preferHighlight: Bool = false) {
        var name: String? = preferHighlight ? model.highlightedKind : nil
        if name == nil, let n = model.selection {
            let f = model.snapshot.flags[n]
            if !f.contains(.directory) || (f.contains(.package) && !model.options.showPackageContents) {
                name = model.snapshot.kind(of: n).name
            }
        }
        if name == nil { name = model.highlightedKind }
        syncing = true
        defer { syncing = false }
        if let name, let row = rows.firstIndex(where: { $0.name == name }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
    }

    // MARK: data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let selected = tableView.selectedRow >= 0 ? rows[tableView.selectedRow].name : nil
        sortRows()
        syncing = true
        tableView.reloadData()
        if let selected, let row = rows.firstIndex(where: { $0.name == selected }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        syncing = false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, row < rows.count else { return nil }
        let stat = rows[row]
        if id == Self.colorColumn {
            let view = (tableView.makeView(withIdentifier: id, owner: nil) as? NSImageView) ?? {
                let v = NSImageView()
                v.identifier = id
                v.imageScaling = .scaleAxesIndependently
                return v
            }()
            view.image = swatch(for: stat, width: tableColumn!.width, height: tableView.rowHeight)
            return view
        }
        let view = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? Self.makeTextCell(id, right: id != Self.kindColumn)
        switch id {
        case Self.kindColumn: view.textField?.stringValue = stat.name
        case Self.sizeColumn: view.textField?.stringValue = Format.size(stat.size)
        default: view.textField?.stringValue = Format.count(stat.fileCount)
        }
        return view
    }

    static func makeTextCell(_ id: NSUserInterfaceItemIdentifier, right: Bool) -> NSTableCellView {
        let view = NSTableCellView()
        view.identifier = id
        let field = NSTextField(labelWithString: "")
        field.alignment = right ? .right : .left
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = right ? .byClipping : .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.addSubview(field)
        view.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {}

    func tableViewColumnDidResize(_ notification: Notification) {
        if (notification.userInfo?["NSTableColumn"] as? NSTableColumn)?.identifier == Self.colorColumn {
            swatches.removeAll()
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< rows.count),
                                 columnIndexes: IndexSet(integer: 0))
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing else { return }
        let row = tableView.selectedRow
        model.highlightKind(row >= 0 && row < rows.count ? rows[row].name : nil)
    }

    /// the cushion swatch, like the treemap's cells (cached per kind and size)
    private func swatch(for stat: KindStatistic, width: CGFloat, height: CGFloat) -> NSImage? {
        let key = "\(stat.name)|\(width)x\(height)"
        if let s = swatches[key] { return s }
        let scale = tableView.window?.backingScaleFactor ?? 2
        let w = max(1, Int((width * scale).rounded())), h = max(1, Int((height * scale).rounded()))
        guard let kind = stat.kinds.first,
              let cg = model.treemapModel.kindColors.swatch(forKind: kind, pixelWidth: w, pixelHeight: h).makeCGImage() else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
        swatches[key] = image
        return image
    }

    /// a click highlights the clicked kind, even when its row was already selected
    @objc private func clicked(_ sender: Any?) {
        let row = tableView.clickedRow
        if row < 0 { tableView.deselectAll(nil) }
        model.highlightKind(row >= 0 && row < rows.count ? rows[row].name : nil)
    }

    @objc func showFilesInSelectionList(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        onShowFilesOfKind?(rows[row].name)
    }
}
