//
//  SelectionListController.swift
//  DIXApp
//
//  The selection list (the original's bottom drawer, SelectionListController):
//  "Show all files of kind:" a kind or all kinds, a search field (All, Name,
//  Kind, Path), and the files in a table with Name, Size and Path. Selecting a
//  row selects the file in the outline and the treemap.
//
//  Lists can have millions of rows; they are filtered and sorted off the main
//  thread while the little spinner turns, as in the original.
//
//  GPL v3
//

import AppKit
import DIXCore
import DIXTreemap

final class SelectionListController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    enum SearchScope: Int { case all, name, kind, path }

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 456, height: 167))
    let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 456, height: 137))
    private let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 456, height: 137))
    let kindPopup = NSPopUpButton(frame: NSRect(x: 145, y: 141, width: 185, height: 22), pullsDown: false)
    let searchField = NSSearchField(frame: NSRect(x: 349, y: 143, width: 107, height: 22))
    private let spinner = NSProgressIndicator(frame: NSRect(x: 330, y: 146, width: 16, height: 16))
    private let label = NSTextField(labelWithString: "Show all files of kind:")

    private let model: DocumentModel
    private var observer = 0
    private(set) var rows: [Int32] = []
    private var generation = 0
    private var scope: SearchScope = .all
    private var syncing = false
    private let queue = DispatchQueue(label: "dix.selectionlist", qos: .userInitiated)
    /// whether the list is on screen (it is computed only then)
    var isActive = false { didSet { if isActive && !oldValue && needsRecompute { recompute() } } }
    private var needsRecompute = true

    static let nameColumn = NSUserInterfaceItemIdentifier("displayName")
    static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    static let pathColumn = NSUserInterfaceItemIdentifier("displayPath")
    static let allKinds = "(all kinds)"

    init(model: DocumentModel) {
        self.model = model
        super.init()
        view.autoresizesSubviews = true

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.frame = NSRect(x: 8, y: 146, width: 135, height: 14)
        label.autoresizingMask = [.minYMargin]
        kindPopup.controlSize = .small
        kindPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        kindPopup.autoresizingMask = [.minYMargin]
        kindPopup.target = self
        kindPopup.action = #selector(kindChosen(_:))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.autoresizingMask = [.minXMargin, .minYMargin]
        searchField.placeholderString = "search"
        searchField.autoresizingMask = [.minXMargin, .minYMargin]
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(search(_:))
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        let menu = NSMenu(title: "Search")
        for (title, s) in [("All", SearchScope.all), ("Name", .name), ("Kind", .kind), ("Path", .path)] {
            let item = menu.addItem(withTitle: title, action: #selector(setScope(_:)), keyEquivalent: "")
            item.tag = s.rawValue
            item.target = self
        }
        searchField.searchMenuTemplate = menu

        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, _ width: CGFloat, key: String, ascending: Bool) -> NSTableColumn {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = 30
            c.maxWidth = 3000
            c.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: ascending)
            c.resizingMask = [.autoresizingMask, .userResizingMask]
            return c
        }
        tableView.addTableColumn(column(Self.nameColumn, "Name", 200, key: "displayName", ascending: true))
        tableView.addTableColumn(column(Self.sizeColumn, "Size", 70, key: "size", ascending: false))
        tableView.addTableColumn(column(Self.pathColumn, "Path", 300, key: "displayPath", ascending: true))
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 17
        tableView.intercellSpacing = NSSize(width: 3, height: 2)
        tableView.style = .plain
        tableView.allowsMultipleSelection = false
        tableView.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 456, height: 25))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
        tableView.setAccessibilityLabel("Selection list")
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.autoresizingMask = [.width, .height]

        for v in [label, kindPopup, spinner, searchField, scrollView] as [NSView] { view.addSubview(v) }
        layoutSubviews()

        observer = model.observe { [weak self] change in self?.modelChanged(change) }
        rebuildKindPopup(select: Self.allKinds)
    }

    deinit { model.removeObserver(observer) }

    /// fixed positions from the original nib, kept as the pane is resized
    func layoutSubviews() {
        let w = view.bounds.width, h = view.bounds.height
        label.frame = NSRect(x: 8, y: h - 21, width: 135, height: 14)
        kindPopup.frame = NSRect(x: 145, y: h - 26, width: 185, height: 22)
        searchField.frame = NSRect(x: w - 160, y: h - 26, width: 160, height: 22)
        spinner.frame = NSRect(x: w - 181, y: h - 22, width: 16, height: 16)
        scrollView.frame = NSRect(x: 0, y: 0, width: w, height: max(0, h - 32))
    }

    // MARK: the kind popup

    private func rebuildKindPopup(select name: String?) {
        let current = name ?? kindPopup.titleOfSelectedItem ?? Self.allKinds
        kindPopup.removeAllItems()
        kindPopup.addItem(withTitle: Self.allKinds)
        kindPopup.menu?.addItem(.separator())
        let names = model.kindStatistics.entries.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for n in names { kindPopup.addItem(withTitle: n) }
        if kindPopup.item(withTitle: current) != nil { kindPopup.selectItem(withTitle: current) } else { kindPopup.selectItem(at: 0) }
    }

    /// shows the files of one kind ("Show Files in Selection List")
    func showKind(_ name: String) {
        if kindPopup.item(withTitle: name) == nil { rebuildKindPopup(select: nil) }
        kindPopup.selectItem(withTitle: name)
        recompute()
    }

    var selectedKind: String? {
        let t = kindPopup.titleOfSelectedItem
        return t == nil || t == Self.allKinds ? nil : t
    }

    @objc private func kindChosen(_ sender: Any?) { recompute() }
    @objc private func search(_ sender: Any?) { recompute() }

    func controlTextDidChange(_ obj: Notification) { recompute() }

    @objc private func setScope(_ sender: NSMenuItem) {
        scope = SearchScope(rawValue: sender.tag) ?? .all
        if !searchField.stringValue.isEmpty { recompute() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(setScope(_:)) { menuItem.state = menuItem.tag == scope.rawValue ? .on : .off }
        return true
    }

    // MARK: computing the list

    private func modelChanged(_ change: DocumentModel.Change) {
        switch change {
        case .snapshot, .options:
            rebuildKindPopup(select: nil)
            if isActive { recompute() } else { needsRecompute = true; rows = []; tableView.reloadData() }
        case .selection:
            if model.selectionOrigin !== self { syncSelection() }
        case .zoom, .highlight: break
        }
    }

    struct Query: Sendable {
        var kindNames: Set<String>?
        var search: String
        var scope: SearchScope
        var sortKey: String
        var ascending: Bool
        var sizeMode: SizeMode
        var showPackageContents: Bool
    }

    /// the files matching a query, sorted (pure; runs on any thread)
    static func rows(for q: Query, in s: Snapshot, cancelled: () -> Bool = { false }) -> [Int32] {
        var kindSet: [Bool]? = nil
        if let names = q.kindNames {
            kindSet = s.kinds.map { names.contains($0.name) }
        }
        var out: [Int32] = []
        var stack: [Int] = [Snapshot.root]
        while let node = stack.popLast() {
            let f = s.flags[node]
            let leaf = !f.contains(.directory) || (f.contains(.package) && !q.showPackageContents && node != Snapshot.root)
            if leaf {
                if let ks = kindSet, !ks[Int(s.kindIndex[node])] { continue }
                out.append(Int32(node))
            } else {
                stack.append(contentsOf: s.children(of: node))
            }
        }
        if cancelled() { return [] }
        let needle = q.search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            func has(_ text: String) -> Bool { text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            out = out.filter { n in
                let node = Int(n)
                switch q.scope {
                case .name: return has(s.name(of: node))
                case .kind: return has(s.kind(of: node).name)
                case .path: return has(s.path(of: node))
                case .all: return has(s.name(of: node)) || has(s.kind(of: node).name) || has(s.path(of: node))
                }
            }
        }
        if cancelled() { return [] }
        let sizes = q.sizeMode == .allocated ? s.allocatedSize : s.logicalSize
        switch q.sortKey {
        case "displayName":
            let names = Dictionary(uniqueKeysWithValues: out.map { ($0, s.name(of: Int($0))) })
            out.sort {
                let r = names[$0]!.compare(names[$1]!, options: [.caseInsensitive, .numeric])
                return r == .orderedSame ? $0 < $1 : (q.ascending ? r == .orderedAscending : r == .orderedDescending)
            }
        case "displayPath":
            let paths = Dictionary(uniqueKeysWithValues: out.map { ($0, s.path(of: Int($0))) })
            out.sort {
                let r = paths[$0]!.compare(paths[$1]!, options: [.caseInsensitive, .numeric])
                return r == .orderedSame ? $0 < $1 : (q.ascending ? r == .orderedAscending : r == .orderedDescending)
            }
        default:
            out.sort {
                let a = sizes[Int($0)], b = sizes[Int($1)]
                return a != b ? (q.ascending ? a < b : a > b) : $0 < $1
            }
        }
        return out
    }

    func recompute() {
        guard isActive else { needsRecompute = true; return }
        needsRecompute = false
        generation += 1
        let gen = generation
        let d = tableView.sortDescriptors.first
        let q = Query(kindNames: selectedKind.map { [$0] }, search: searchField.stringValue, scope: scope,
                      sortKey: d?.key ?? "size", ascending: d?.ascending ?? false,
                      sizeMode: model.options.sizeMode, showPackageContents: model.options.showPackageContents)
        let snapshot = model.snapshot
        spinner.startAnimation(nil)
        token?.cancel()
        let token = CancelToken()
        self.token = token
        queue.async { [weak self] in
            let rows = Self.rows(for: q, in: snapshot, cancelled: { token.isCancelled })
            DispatchQueue.main.async {
                guard let me = self, me.generation == gen else { return }
                me.spinner.stopAnimation(nil)
                me.rows = rows
                me.syncing = true
                me.tableView.reloadData()
                me.syncing = false
                me.syncSelection()
            }
        }
    }

    private var token: CancelToken?

    /// computes synchronously (tests, offscreen rendering)
    func recomputeNow() {
        token?.cancel()
        spinner.stopAnimation(nil)
        let d = tableView.sortDescriptors.first
        let q = Query(kindNames: selectedKind.map { [$0] }, search: searchField.stringValue, scope: scope,
                      sortKey: d?.key ?? "size", ascending: d?.ascending ?? false,
                      sizeMode: model.options.sizeMode, showPackageContents: model.options.showPackageContents)
        generation += 1
        rows = Self.rows(for: q, in: model.snapshot)
        needsRecompute = false
        tableView.reloadData()
        syncSelection()
    }

    private func syncSelection() {
        syncing = true
        defer { syncing = false }
        guard let n = model.selection, let row = rows.firstIndex(of: Int32(n)) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        recompute()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, row < rows.count else { return nil }
        let n = Int(rows[row])
        let s = model.snapshot
        let view = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView)
            ?? KindsTableController.makeTextCell(id, right: false)
        switch id {
        case Self.nameColumn: view.textField?.stringValue = s.name(of: n)
        case Self.sizeColumn: view.textField?.stringValue = Format.size(model.size(of: n))
        default:
            view.textField?.stringValue = (s.path(of: Int(s.parent[n])) as NSString).abbreviatingWithTildeInPath
            view.textField?.lineBreakMode = .byTruncatingMiddle
        }
        return view
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < rows.count else { return nil }
        let path = model.snapshot.path(of: Int(rows[row]))
        return FileManager.default.fileExists(atPath: path) ? NSURL(fileURLWithPath: path) : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        let node = Int(rows[row])
        // a file outside the zoomed folder: zoom out to the top first
        if !model.snapshot.isNode(node, inSubtreeOf: model.zoomedNode) { model.zoomOut(to: Snapshot.root) }
        model.select(node, origin: self)
    }
}

/// A flag a background job polls to stop early.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
