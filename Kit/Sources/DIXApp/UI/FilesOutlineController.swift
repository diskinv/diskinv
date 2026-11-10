//
//  FilesOutlineController.swift
//  DIXApp
//
//  The file outline left of the treemap (FilesOutlineViewController in the
//  original): the zoomed folder's contents, largest first, with the original's
//  Name and Size columns. Selection follows the document both ways.
//
//  NSOutlineView needs an object per item; snapshots have millions of nodes,
//  so items are boxed lazily, only for rows the outline actually asks about,
//  and kept in a table so the same node is always the same object.
//
//  GPL v3
//

import AppKit
import DIXCore
import DIXTreemap
import UniformTypeIdentifiers

/// A node boxed for NSOutlineView (identity matters: one object per node).
final class NodeItem: NSObject {
    fileprivate(set) var node: NodeIndex
    init(_ node: NodeIndex) { self.node = node }
}

/// NSOutlineView that selects the row under a right click before showing the
/// context menu (DIXOutlineView in the original).
final class FilesOutlineView: NSOutlineView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !isRowSelected(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        window?.makeFirstResponder(self)
        return contextMenuProvider?(row)
    }
}

final class FilesOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outlineView: FilesOutlineView
    let scrollView: NSScrollView
    private let model: DocumentModel
    private var observer = 0
    private var items: [Int32: NodeItem] = [:]
    /// children in display order, cached per folder (logical mode only;
    /// in allocated mode the snapshot's order is the display order)
    private var childCache: [Int32: [Int32]] = [:]
    private var settingSelection = false
    private var icons = IconCache()
    var contextMenu: NSMenu?
    /// double-click on a row
    var onDoubleClick: ((NodeIndex) -> Void)?

    static let nameColumn = NSUserInterfaceItemIdentifier("displayName")
    static let sizeColumn = NSUserInterfaceItemIdentifier("size")

    init(model: DocumentModel) {
        self.model = model
        outlineView = FilesOutlineView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        super.init()

        let name = NSTableColumn(identifier: Self.nameColumn)
        name.title = "Name"
        name.width = 150
        name.minWidth = 16
        name.maxWidth = 1000
        name.resizingMask = [.autoresizingMask, .userResizingMask]
        let size = NSTableColumn(identifier: Self.sizeColumn)
        size.title = "Size"
        size.headerCell.alignment = .right
        size.width = 72
        size.minWidth = 30
        size.maxWidth = 1000
        size.resizingMask = [.autoresizingMask, .userResizingMask]
        outlineView.addTableColumn(name)
        outlineView.addTableColumn(size)
        outlineView.outlineTableColumn = name
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.indentationPerLevel = 16
        outlineView.intercellSpacing = NSSize(width: 3, height: 2)
        outlineView.rowHeight = 17
        outlineView.style = .plain
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.autoresizesOutlineColumn = true
        outlineView.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 300, height: 25))
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.setDraggingSourceOperationMask([.copy, .link], forLocal: false)
        outlineView.setDraggingSourceOperationMask([], forLocal: true)
        outlineView.contextMenuProvider = { [weak self] _ in self?.contextMenu }
        outlineView.setAccessibilityLabel("Files")

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        observer = model.observe { [weak self] change in self?.modelChanged(change) }
        outlineView.reloadData()
    }

    deinit { model.removeObserver(observer) }

    // MARK: items

    private func item(_ node: NodeIndex) -> NodeItem {
        let key = Int32(truncatingIfNeeded: node)
        if let i = items[key] { return i }
        let i = NodeItem(node)
        items[key] = i
        return i
    }

    private func node(of item: Any?) -> NodeIndex {
        (item as? NodeItem)?.node ?? model.zoomedNode
    }

    private func child(_ index: Int, of node: NodeIndex) -> NodeIndex {
        let s = model.snapshot
        if model.options.sizeMode == .allocated { return Int(s.firstChild[node]) + index }
        let key = Int32(truncatingIfNeeded: node)
        if let cached = childCache[key] { return Int(cached[index]) }
        let ordered = model.orderedChildren(of: node).map { Int32(truncatingIfNeeded: $0) }
        childCache[key] = ordered
        return Int(ordered[index])
    }

    // MARK: data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let n = node(of: item)
        guard item == nil || model.isContainer(n) else { return 0 }
        return Int(model.snapshot.childCount[n])
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        self.item(child(index, of: node(of: item)))
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        let n = node(of: item)
        return n != model.zoomedNode && model.isContainer(n)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        let path = model.snapshot.path(of: node(of: item))
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSURL(fileURLWithPath: path)
    }

    // MARK: delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let n = node(of: item)
        let s = model.snapshot
        if tableColumn?.identifier == Self.sizeColumn {
            let view = (outlineView.makeView(withIdentifier: Self.sizeColumn, owner: nil) as? NSTableCellView) ?? Self.makeSizeCell()
            view.textField?.stringValue = Format.size(model.size(of: n))
            return view
        }
        let view = (outlineView.makeView(withIdentifier: Self.nameColumn, owner: nil) as? NameCellView) ?? NameCellView()
        view.identifier = Self.nameColumn
        view.textField?.stringValue = s.name(of: n)
        view.imageView?.image = icons.icon(for: n, in: s)
        let f = s.flags[n]
        view.showsCloud = f.contains(.cloudPlaceholder)
        view.textField?.textColor = f.contains(.unreadable) || f.contains(.hardLinkDuplicate) && model.options.sizeMode == .allocated
            ? .secondaryLabelColor : .labelColor
        view.toolTip = f.contains(.cloudPlaceholder)
            ? HoverText.cloudNote(path: s.path(of: n), sizeMode: model.options.sizeMode, logical: s.logicalSize[n]).capitalizingFirst
            : (f.contains(.unreadable) ? "This folder couldn't be read" : nil)
        return view
    }

    private static func makeSizeCell() -> NSTableCellView {
        let view = NSTableCellView()
        view.identifier = sizeColumn
        let field = NSTextField(labelWithString: "")
        field.alignment = .right
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byClipping
        field.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(field)
        view.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !settingSelection else { return }
        let row = outlineView.selectedRow
        let n = row >= 0 ? (outlineView.item(atRow: row) as? NodeItem)?.node : nil
        model.select(n, origin: self)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let n = (outlineView.item(atRow: row) as? NodeItem)?.node else { return }
        onDoubleClick?(n)
    }

    // MARK: document changes

    private func modelChanged(_ change: DocumentModel.Change) {
        switch change {
        case .selection:
            if model.selectionOrigin !== self { revealSelection() }
        case .zoom:
            reload()
        case .options:
            childCache.removeAll()
            reload()
        case .snapshot:
            remapItems()
            childCache.removeAll()
            icons.removeNodeIcons()
            reload()
        case .highlight:
            break
        }
    }

    private func reload() {
        settingSelection = true
        outlineView.reloadData()
        settingSelection = false
        revealSelection()
    }

    /// follow the new snapshot's indexes, keeping the same objects (and so the
    /// outline's expanded state) for nodes that are still there
    private func remapItems() {
        guard let map = model.lastIndexMap else { items.removeAll(); return }
        var remapped: [Int32: NodeItem] = [:]
        for (_, item) in items {
            guard item.node < map.count, map[item.node] != .max else { continue }
            item.node = Int(map[item.node])
            remapped[Int32(truncatingIfNeeded: item.node)] = item
        }
        items = remapped
    }

    /// select the document's selection, expanding its ancestors
    func revealSelection() {
        settingSelection = true
        defer { settingSelection = false }
        guard let target = model.selection, target != model.zoomedNode else {
            outlineView.deselectAll(nil)
            return
        }
        let s = model.snapshot
        let chain = s.ancestry(of: target)
        guard let zi = chain.firstIndex(of: model.zoomedNode) else { outlineView.deselectAll(nil); return }
        for n in chain[(zi + 1)...].dropLast() {
            guard model.isContainer(n) else { break }
            outlineView.expandItem(item(n))
        }
        let row = outlineView.row(forItem: item(target))
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    /// the rect of the selected row (for the trash "poof")
    var selectedRowRect: NSRect? {
        let row = outlineView.selectedRow
        return row >= 0 ? outlineView.rect(ofRow: row) : nil
    }
}

/// Name cell: icon, name, and a cloud badge for placeholders.
final class NameCellView: NSTableCellView {
    private let cloud = NSImageView()
    private var trailing: NSLayoutConstraint!

    var showsCloud = false {
        didSet {
            cloud.isHidden = !showsCloud
            trailing.constant = showsCloud ? -20 : -2
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 17))
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cloud.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: "in the cloud, not on this Mac")
        cloud.contentTintColor = .secondaryLabelColor
        cloud.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        cloud.translatesAutoresizingMaskIntoConstraints = false
        cloud.isHidden = true
        addSubview(image)
        addSubview(field)
        addSubview(cloud)
        imageView = image
        textField = field
        trailing = field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing,
            cloud.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
            cloud.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// File icons without touching the disk for ordinary files: one icon per kind
/// (from its type), folders share one; packages (apps) get their own icon.
struct IconCache {
    private var byKind: [Int: NSImage] = [:]
    private var byNode: [Int: NSImage] = [:]
    private static let folder: NSImage = {
        let i = NSWorkspace.shared.icon(for: .folder)
        i.size = NSSize(width: 16, height: 16)
        return i
    }()
    private static let symlink: NSImage = {
        let i = NSWorkspace.shared.icon(for: .symbolicLink)
        i.size = NSSize(width: 16, height: 16)
        return i
    }()

    mutating func removeNodeIcons() { byNode.removeAll() }

    mutating func icon(for node: NodeIndex, in s: Snapshot) -> NSImage {
        let f = s.flags[node]
        if f.contains(.package) || node == Snapshot.root {
            if let i = byNode[node] { return i }
            let path = s.path(of: node)
            let i: NSImage
            if FileManager.default.fileExists(atPath: path) {
                i = NSWorkspace.shared.icon(forFile: path)
            } else {
                let id = s.kind(of: node).identifier
                i = NSWorkspace.shared.icon(for: UTType(id) ?? .package)
            }
            i.size = NSSize(width: 16, height: 16)
            byNode[node] = i
            return i
        }
        if f.contains(.directory) { return Self.folder }
        if f.contains(.symlink) { return Self.symlink }
        let k = Int(s.kindIndex[node])
        if let i = byKind[k] { return i }
        let id = s.kinds[k].identifier
        let i = NSWorkspace.shared.icon(for: UTType(id) ?? .data)
        i.size = NSSize(width: 16, height: 16)
        byKind[k] = i
        return i
    }
}

extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}
