//
//  DocumentWindowController.swift
//  DIXApp
//
//  The document window, laid out as the original's TreeMap.nib: the file
//  outline and the treemap side by side in a split view with 20-point
//  margins, the two status lines under them, the toolbar (Zoom In, Zoom Out,
//  File Kind Statistics, ...), the kinds statistics on the left and the
//  selection list at the bottom where the original's drawers were, toggled
//  the same way. Also the menu and toolbar actions (MainWindowController).
//
//  GPL v3
//

import AppKit
import DIXCore
import DIXScan
import DIXTreemap

public final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, NSToolbarItemValidation, TreemapViewDelegate, NSMenuDelegate, NSSplitViewDelegate {

    let model: DocumentModel
    let treemapView = TreemapView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    let outline: FilesOutlineController
    let kinds: KindsTableController
    let selectionList: SelectionListController
    let nameField = NSTextField(labelWithString: "")
    let sizeField = NSTextField(labelWithString: "")
    let notice = NoticeBar(frame: NSRect(x: 0, y: 0, width: 400, height: NoticeBar.height))
    let filesSplit = NSSplitView(frame: NSRect(x: 0, y: 0, width: 532, height: 436))
    private(set) var outerSplit: NSSplitViewController!
    private(set) var columnSplit: NSSplitViewController!
    private var kindsItem: NSSplitViewItem!
    private var selectionItem: NSSplitViewItem!
    private var observer = 0
    private let contextMenu = NSMenu(title: "File")
    private let openWithMenu = NSMenu(title: "Open With")
    private var hoverActive = false
    /// minimum treemap cell area in square points (merging below it)
    var treemapOptionsOverride: TreemapOptions?

    private weak var initialDocument: ScanDocument?
    var scanDocument: ScanDocument? { (document as? ScanDocument) ?? initialDocument }

    init(document: ScanDocument) {
        model = document.model
        outline = FilesOutlineController(model: model)
        kinds = KindsTableController(model: model)
        selectionList = SelectionListController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.minSize = NSSize(width: 420, height: 300)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false   // as the original: never reopen (rescan) windows at launch
        super.init(window: window)
        initialDocument = document
        shouldCascadeWindows = true
        window.delegate = self
        buildContent()
        buildToolbar()
        buildContextMenu()
        observer = model.observe { [weak self] change in self?.modelChanged(change) }
        windowFrameAutosaveName = "MainWindow"
        updateTitle()
        showInitialNotice(for: document)
        updateTreemap()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { model.removeObserver(observer) }

    // MARK: building the window

    /// the main area: notice, outline | treemap, and the two status lines
    final class MainAreaView: NSView {
        weak var controller: DocumentWindowController?
        override func layout() {
            super.layout()
            guard let c = controller else { return }
            let w = bounds.width, h = bounds.height
            var top: CGFloat = 20
            if !c.notice.isHidden {
                c.notice.frame = NSRect(x: 20, y: h - 12 - NoticeBar.height, width: max(0, w - 40), height: NoticeBar.height)
                top = 12 + NoticeBar.height + 10
            }
            c.filesSplit.frame = NSRect(x: 20, y: 65, width: max(0, w - 40), height: max(0, h - 65 - top))
            c.nameField.frame = NSRect(x: 17, y: 42, width: max(0, w - 34), height: 17)
            c.sizeField.frame = NSRect(x: 17, y: 20, width: max(0, w - 34), height: 14)
        }
    }

    final class PaneView: NSView {
        var inner: NSView?
        var insets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        override func layout() {
            super.layout()
            inner?.frame = NSRect(x: insets.left, y: insets.bottom,
                                  width: max(0, bounds.width - insets.left - insets.right),
                                  height: max(0, bounds.height - insets.top - insets.bottom))
        }
    }

    private func buildContent() {
        // outline | treemap
        filesSplit.isVertical = !UserDefaults.standard.bool(forKey: "SplitWindowHorizontally")
        filesSplit.dividerStyle = .thick
        filesSplit.delegate = self
        outline.scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 436)
        filesSplit.addSubview(outline.scrollView)
        filesSplit.addSubview(treemapView)
        filesSplit.autosaveName = "MainWindowSplitter"
        filesSplit.setHoldingPriority(.init(260), forSubviewAt: 0)
        filesSplit.setHoldingPriority(.init(250), forSubviewAt: 1)
        treemapView.delegate = self
        treemapView.setAccessibilityLabel("Treemap")
        outline.contextMenu = contextMenu
        outline.onDoubleClick = { [weak self] node in
            guard let self, self.model.snapshot.isDirectory(node), self.model.snapshot.childCount[node] > 0 else { return }
            self.model.select(node)
            self.model.zoomIn()
        }

        nameField.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameField.lineBreakMode = .byTruncatingTail
        sizeField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeField.lineBreakMode = .byTruncatingTail
        nameField.setAccessibilityLabel("Item under the pointer")
        sizeField.setAccessibilityLabel("Kind and size")
        notice.isHidden = true
        notice.onDismiss = { [weak self] in self?.mainArea.needsLayout = true }

        mainArea.controller = self
        for v in [notice, filesSplit, nameField, sizeField] as [NSView] { mainArea.addSubview(v) }

        // where the drawers were: kinds on the left, the selection list at the bottom
        let kindsPane = PaneView()
        kindsPane.inner = kinds.scrollView
        kindsPane.insets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 0)
        kindsPane.addSubview(kinds.scrollView)
        let selectionPane = PaneView()
        selectionPane.inner = selectionList.view
        selectionPane.insets = NSEdgeInsets(top: 4, left: 20, bottom: 20, right: 20)
        selectionPane.addSubview(selectionList.view)
        selectionList.view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: selectionList.view,
                                               queue: .main) { [weak self] _ in self?.selectionList.layoutSubviews() }

        let mainVC = NSViewController()
        mainVC.view = mainArea
        let selectionVC = NSViewController()
        selectionVC.view = selectionPane
        columnSplit = NSSplitViewController()
        columnSplit.splitView.isVertical = false
        columnSplit.splitView.dividerStyle = .thin
        let mainItem = NSSplitViewItem(viewController: mainVC)
        mainItem.holdingPriority = .init(250)
        mainItem.minimumThickness = 200
        selectionItem = NSSplitViewItem(viewController: selectionVC)
        selectionItem.canCollapse = true
        selectionItem.holdingPriority = .init(260)
        selectionItem.minimumThickness = 110
        selectionItem.isCollapsed = true
        columnSplit.addSplitViewItem(mainItem)
        columnSplit.addSplitViewItem(selectionItem)

        let kindsVC = NSViewController()
        kindsVC.view = kindsPane
        outerSplit = NSSplitViewController()
        outerSplit.splitView.isVertical = true
        outerSplit.splitView.dividerStyle = .thin
        kindsItem = NSSplitViewItem(viewController: kindsVC)
        kindsItem.canCollapse = true
        kindsItem.holdingPriority = .init(260)
        kindsItem.minimumThickness = 150
        kindsItem.maximumThickness = 700
        let columnItem = NSSplitViewItem(viewController: columnSplit)
        columnItem.holdingPriority = .init(250)
        columnItem.minimumThickness = 300
        outerSplit.addSplitViewItem(kindsItem)
        outerSplit.addSplitViewItem(columnItem)
        outerSplit.splitView.autosaveName = "KindsSplitter"
        // the original opens the kinds drawer with every window
        kindsItem.isCollapsed = false

        let frame = window!.frame
        window!.contentViewController = outerSplit
        window!.setFrame(frame, display: false)
        // first layout: kinds pane 330 wide (the drawer's width), outline a third of the rest
        outerSplit.splitView.setPosition(330, ofDividerAt: 0)
        DispatchQueue.main.async { [weak self] in self?.initialSplitPositions() }
        initialSplitPositions()
    }

    let mainArea = MainAreaView()
    private var didPositionSplits = false

    private func initialSplitPositions() {
        guard !didPositionSplits else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        mainArea.layoutSubtreeIfNeeded()
        let w = filesSplit.bounds.width
        guard w > 100 else { return }
        didPositionSplits = true
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MainWindowSplitter") == nil {
            filesSplit.setPosition(filesSplit.isVertical ? min(340, (w * 0.38).rounded()) : (filesSplit.bounds.height * 0.4).rounded(),
                                   ofDividerAt: 0)
        }
    }

    // MARK: notices

    private func showInitialNotice(for document: ScanDocument) {
        if document.isSavedScan {
            let s = model.snapshot
            let date = DateFormatter.localizedString(from: s.scanDate, dateStyle: .medium, timeStyle: .short)
            let exists = FileManager.default.fileExists(atPath: s.rootPath)
            showNotice(exists ? "Saved scan of “\(ScanDocument.displayName(forRoot: s) ?? s.rootPath)” from \(date). Refresh to scan the folder again."
                              : "Saved scan of \((s.rootPath as NSString).abbreviatingWithTildeInPath) from \(date). The folder isn’t on this Mac now.",
                       style: .info, button: exists ? "Refresh" : nil) { [weak self] in
                self?.refreshAll(nil)
            }
        } else if document.unreadableFolders > 0 {
            showUnreadableNotice(document.unreadableFolders)
        }
    }

    func showUnreadableNotice(_ count: Int) {
        let folders = count == 1 ? "1 folder couldn’t be read" : "\(Format.count(count)) folders couldn’t be read"
        showNotice("\(folders). To include the folders macOS protects, give Disk Inventory X Full Disk Access.",
                   style: .warning, button: "Open Full Disk Access Settings…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        }
    }

    func showNotice(_ text: String, style: NoticeBar.Style, button: String?, action: (() -> Void)?) {
        notice.show(text, style: style, buttonTitle: button, action: action)
        mainArea.needsLayout = true
    }

    func hideNotice() {
        notice.isHidden = true
        mainArea.needsLayout = true
    }

    // MARK: toolbar

    enum ToolbarID {
        static let zoomIn = NSToolbarItem.Identifier("ZoomIn")
        static let zoomOut = NSToolbarItem.Identifier("ZoomOut")
        static let kinds = NSToolbarItem.Identifier("ToggleKindsStatisticDrawer")
        static let info = NSToolbarItem.Identifier("ShowInfo")
        static let preferences = NSToolbarItem.Identifier("ShowPreferences")
        static let packages = NSToolbarItem.Identifier("ShowPackageContents")
        static let reveal = NSToolbarItem.Identifier("RevealInFinder")
        static let refresh = NSToolbarItem.Identifier("RefreshSelection")
        static let refreshAll = NSToolbarItem.Identifier("RefreshAll")
        static let trash = NSToolbarItem.Identifier("MoveToTrash")
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "MainWindowToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconAndLabel
        window?.toolbar = toolbar
        window?.toolbarStyle = .expanded
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.zoomIn, ToolbarID.zoomOut, .flexibleSpace, ToolbarID.kinds]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.info, ToolbarID.preferences, ToolbarID.kinds, ToolbarID.packages, ToolbarID.zoomIn, ToolbarID.zoomOut,
         ToolbarID.reveal, ToolbarID.refresh, ToolbarID.refreshAll, ToolbarID.trash, .space, .flexibleSpace]
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let specs: [NSToolbarItem.Identifier: (label: String, image: String, action: Selector, tip: String)] = [
            ToolbarID.zoomIn: ("Zoom In", "ZoomIn", #selector(zoomIn(_:)), "Zoom in selected folder"),
            ToolbarID.zoomOut: ("Zoom Out", "ZoomOut", #selector(zoomOut(_:)), "Zoom out to previous folder"),
            ToolbarID.kinds: ("Show File Kind Statistics", "KindsStatisticDrawer", #selector(toggleFileKindsDrawer(_:)),
                              "Show/hide the file kind statistic drawer"),
            ToolbarID.info: ("Show Information", "Inspector", #selector(showInformationPanel(_:)), "Show/hide the information window"),
            ToolbarID.preferences: ("Preferences", "Preferences", NSSelectorFromString("showPreferencesPanel:"), "Preferences"),
            ToolbarID.packages: ("Show Package Contents", "ShowPackageContentsOpen", #selector(showPackageContents(_:)),
                                 "Show packages like folders or files"),
            ToolbarID.reveal: ("Reveal in Finder", "RevealInFinder", #selector(showInFinder(_:)),
                               "Reveal the selected file or folder in the Finder"),
            ToolbarID.refresh: ("Refresh Selection", "RefreshSelection", #selector(refresh(_:)),
                                "Synchronize selected folder or file with Finder"),
            ToolbarID.refreshAll: ("Refresh All", "RefreshAll", #selector(refreshAll(_:)), "Synchronize window with Finder"),
            ToolbarID.trash: ("Move To Trash", "MoveToTrash", #selector(moveToTrash(_:)), "Move the selected file or folder to the trash"),
        ]
        guard let spec = specs[id] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = spec.label
        item.paletteLabel = spec.label
        item.toolTip = spec.tip
        item.image = AppResources.image(spec.image)
        item.action = spec.action
        item.target = id == ToolbarID.preferences ? nil : self
        item.autovalidates = true
        return item
    }

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let v = validation(for: item.action)
        if let title = v.title, item.itemIdentifier != ToolbarID.zoomIn {
            item.label = title
        }
        if item.itemIdentifier == ToolbarID.packages {
            item.image = AppResources.image(model.options.showPackageContents ? "ShowPackageContentsClosed" : "ShowPackageContentsOpen")
        }
        return v.enabled
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let v = validation(for: item.action)
        if let title = v.title { item.title = title }
        return v.enabled
    }

    private struct Validation { var enabled = true; var title: String? = nil }

    /// one decision per command, for menu items and toolbar items alike
    private func validation(for action: Selector?) -> Validation {
        let sel = model.selection
        let s = model.snapshot
        switch action {
        case #selector(zoomIn(_:)): return Validation(enabled: model.canZoomIn)
        case #selector(zoomOut(_:)): return Validation(enabled: model.canZoomOut)
        case #selector(zoomOutTo(_:)): return Validation(enabled: model.canZoomOut)
        case #selector(showInFinder(_:)), #selector(copy(_:)):
            return Validation(enabled: sel.map { FileManager.default.fileExists(atPath: s.path(of: $0)) } ?? false)
        case #selector(openFile(_:)):
            return Validation(enabled: sel.map { FileManager.default.fileExists(atPath: s.path(of: $0)) } ?? false)
        case #selector(refresh(_:)):
            return Validation(enabled: sel != nil && !isBusy)
        case #selector(refreshAll(_:)):
            return Validation(enabled: !isBusy && FileManager.default.fileExists(atPath: s.rootPath))
        case #selector(moveToTrash(_:)):
            guard let n = sel, n != model.zoomedNode, n != Snapshot.root, !isBusy else { return Validation(enabled: false) }
            return Validation(enabled: !Self.isInTrash(s.path(of: n)))
        case #selector(showPackageContents(_:)):
            return Validation(title: model.options.showPackageContents ? "Hide Package Contents" : "Show Package Contents")
        case #selector(showFreeSpace(_:)):
            return Validation(enabled: s.volume != nil, title: model.options.showFreeSpace ? "Hide Free Space" : "Show Free Space")
        case #selector(showOtherSpace(_:)):
            let isVolume = s.volume.map { s.path(of: model.zoomedNode) == $0.mountPath } ?? true
            return Validation(enabled: !isVolume, title: model.options.showOtherSpace ? "Hide Other Space" : "Show Other Space")
        case #selector(showPhysicalSizes(_:)):
            return Validation(title: model.options.sizeMode == .allocated ? "Show Logical File Size" : "Show Physical File Size")
        case #selector(toggleFileKindsDrawer(_:)):
            return Validation(title: kindsItem.isCollapsed ? "Show File Kind Statistics" : "Hide File Kind Statistics")
        case #selector(toggleSelectionListDrawer(_:)):
            return Validation(title: selectionItem.isCollapsed ? "Show Selection List" : "Hide Selection List")
        case #selector(selectParentItem(_:)): return Validation(enabled: model.canSelectParent)
        case #selector(changeSplitting(_:)):
            return Validation(title: filesSplit.isVertical ? "Split Horizontally" : "Split Vertically")
        case #selector(showInformationPanel(_:)):
            return Validation(title: InfoPanelController.shared.isVisible ? "Hide Information" : "Show Information")
        default: return Validation()
        }
    }

    static func isInTrash(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false) else {
            return false
        }
        return path == trash.path || path.hasPrefix(trash.path + "/")
    }

    // MARK: context menu

    private func buildContextMenu() {
        contextMenu.addItem(withTitle: "Open", action: #selector(openFile(_:)), keyEquivalent: "").target = self
        let openWith = contextMenu.addItem(withTitle: "Open With", action: nil, keyEquivalent: "")
        openWithMenu.delegate = self
        openWith.submenu = openWithMenu
        contextMenu.addItem(.separator())
        contextMenu.addItem(withTitle: "Reveal in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "").target = self
        let refresh = contextMenu.addItem(withTitle: "Refresh", action: #selector(refresh(_:)), keyEquivalent: "")
        refresh.target = self
        refresh.toolTip = "Synchronizes folder or file with Finder."
        contextMenu.addItem(.separator())
        contextMenu.addItem(withTitle: "Move To Trash", action: #selector(moveToTrash(_:)), keyEquivalent: "").target = self
        contextMenu.addItem(.separator())
        contextMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "").target = self
        contextMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "").target = self
    }

    /// the Open With submenu: the default app, a separator, the other apps
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openWithMenu else { return }
        menu.removeAllItems()
        guard let n = model.selection else { return }
        let url = URL(fileURLWithPath: model.snapshot.path(of: n))
        let ws = NSWorkspace.shared
        guard let defaultApp = ws.urlForApplication(toOpen: url) else { return }
        func add(_ app: URL) {
            let item = menu.addItem(withTitle: FileManager.default.displayName(atPath: app.path),
                                    action: #selector(openFile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            item.toolTip = app.path
            let icon = ws.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        add(defaultApp)
        let others = ws.urlsForApplications(toOpen: url).filter { $0.standardizedFileURL != defaultApp.standardizedFileURL }
        if !others.isEmpty { menu.addItem(.separator()) }
        for app in others.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            add(app)
        }
    }

    // MARK: model changes

    private func modelChanged(_ change: DocumentModel.Change) {
        switch change {
        case .selection:
            treemapView.selectedNode = model.selection
            if InfoPanelController.shared.isVisible && window?.isMainWindow == true {
                InfoPanelController.shared.show(model.selection.map { (model, $0) })
            }
        case .zoom:
            updateTreemap()
            updateTitle()
        case .options, .snapshot:
            updateTreemap()
            updateTitle()
        case .highlight:
            updateHighlight()
        }
        window?.toolbar?.validateVisibleItems()
    }

    func treemapOptions() -> TreemapOptions {
        var o = treemapOptionsOverride ?? TreemapOptions()
        o.showFreeSpace = model.options.showFreeSpace
        let isVolume = model.snapshot.volume.map { model.snapshot.path(of: model.zoomedNode) == $0.mountPath } ?? true
        o.showOtherSpace = model.options.showOtherSpace && !isVolume
        return o
    }

    func updateTreemap() {
        treemapView.setContent(TreemapView.Content(model: model.treemapModel, root: model.zoomedNode, options: treemapOptions()))
        treemapView.selectedNode = model.selection
        updateHighlight()
    }

    private func updateHighlight() {
        if let name = model.highlightedKind, let stat = model.kindStatistics.entry(named: name) {
            treemapView.highlightedKinds = Set(stat.kinds)
        } else {
            treemapView.highlightedKinds = nil
        }
    }

    private func updateTitle() {
        guard let window else { return }
        window.title = ScanDocument.displayName(forRoot: model.snapshot) ?? "Disk Inventory X"
        var subtitle = ""
        if model.zoomedNode != Snapshot.root {
            subtitle = "Zoomed into " + String(model.snapshot.path(of: model.zoomedNode).dropFirst(model.snapshot.rootPath == "/" ? 1 : model.snapshot.rootPath.count + 1))
        }
        if scanDocument?.isSavedScan == true {
            subtitle = subtitle.isEmpty ? "Saved scan" : "Saved scan · " + subtitle
        }
        if model.options.sizeMode == .logical { subtitle = subtitle.isEmpty ? "File sizes" : subtitle + " · File sizes" }
        window.subtitle = subtitle
        if let path = scanDocument?.fileURL?.path {
            window.representedURL = FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
    }

    public override func synchronizeWindowTitleWithDocumentName() { updateTitle() }

    // MARK: treemap delegate

    func treemapView(_ view: TreemapView, hovered hit: TreemapHit?, pixelX: Int, pixelY: Int) {
        guard let layout = view.layout else { return }
        let text = HoverText.text(for: hit, layout: layout, pixelX: pixelX, pixelY: pixelY)
        nameField.stringValue = text.name
        sizeField.stringValue = text.detail
    }

    func treemapView(_ view: TreemapView, clicked hit: TreemapHit?, clickCount: Int) {
        guard let hit else { return }
        switch hit {
        case .node(let node, _):
            model.select(node, origin: view)
            if clickCount == 2 {
                // double-click: zoom into a folder drawn as one cell, or into the file's folder
                let s = model.snapshot
                let target = s.isDirectory(node) && s.childCount[node] > 0 ? node : Int(s.parent[node])
                if target != model.zoomedNode { model.zoom(into: target) }
            }
        case .merged(let group, _):
            // a merged area stands for its folder's small items: select the largest of them
            guard let largest = view.layout?.mergedMembers(of: group).first else { return }
            if model.selection == nil || !(view.layout?.mergedMembers(of: group).contains(model.selection!) ?? false) {
                model.select(largest, origin: view)
            }
            if clickCount == 2 && group.folder != model.zoomedNode { model.zoom(into: group.folder) }
        case .freeSpace, .otherSpace:
            model.select(nil, origin: view)
        }
    }

    func treemapView(_ view: TreemapView, menuFor hit: TreemapHit?) -> NSMenu? {
        switch hit {
        case .node(let node, _)?: model.select(node, origin: view)
        case .merged(let group, _)?:
            if let largest = view.layout?.mergedMembers(of: group).first { model.select(largest, origin: view) }
        default: return nil
        }
        return contextMenu
    }

    func treemapViewDidRender(_ view: TreemapView) {}

    // MARK: window delegate

    public func windowDidBecomeMain(_ notification: Notification) {
        if InfoPanelController.shared.isVisible {
            InfoPanelController.shared.show(model.selection.map { (model, $0) })
        }
    }

    public func windowWillClose(_ notification: Notification) {
        if InfoPanelController.shared.isVisible, window?.isMainWindow == true {
            InfoPanelController.shared.show(nil)
        }
    }

    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 60)
    }

    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - 60)
    }

    // MARK: actions (names as in the original's MainMenu.nib / MainWindowController)

    @IBAction func toggleFileKindsDrawer(_ sender: Any?) {
        kindsItem.animator().isCollapsed.toggle()
    }

    @IBAction func toggleSelectionListDrawer(_ sender: Any?) {
        setSelectionListVisible(selectionItem.isCollapsed)
    }

    func setSelectionListVisible(_ visible: Bool, animated: Bool = true) {
        if selectionItem.isCollapsed == visible {
            if animated { selectionItem.animator().isCollapsed = !visible } else { selectionItem.isCollapsed = !visible }
            if visible {
                // open at the drawer's height (200) when it would come up smaller
                let split = columnSplit.splitView
                split.layoutSubtreeIfNeeded()
                if split.subviews.count > 1, split.subviews[1].frame.height < 180 {
                    split.setPosition(max(200, split.bounds.height - 200), ofDividerAt: 0)
                }
            }
        }
        selectionList.isActive = visible
    }

    var isKindsPaneVisible: Bool { !kindsItem.isCollapsed }
    var isSelectionListVisible: Bool { !selectionItem.isCollapsed }

    @IBAction func zoomIn(_ sender: Any?) { model.zoomIn() }
    @IBAction func zoomOut(_ sender: Any?) { model.zoomOut() }

    @IBAction func zoomOutTo(_ sender: Any?) {
        guard let node = (sender as? NSMenuItem)?.representedObject as? Int else { return }
        model.zoomOut(to: node)
    }

    @IBAction func selectParentItem(_ sender: Any?) { model.selectParent() }

    @IBAction func showInFinder(_ sender: Any?) {
        guard let n = model.selection else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.snapshot.path(of: n))])
    }

    @IBAction func openFile(_ sender: Any?) {
        guard let n = model.selection else { return }
        let url = URL(fileURLWithPath: model.snapshot.path(of: n))
        let config = NSWorkspace.OpenConfiguration()
        if let app = (sender as? NSMenuItem)?.representedObject as? URL {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @IBAction func copy(_ sender: Any?) {
        guard let n = model.selection else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSURL(fileURLWithPath: model.snapshot.path(of: n))])
    }

    @IBAction func showPackageContents(_ sender: Any?) {
        var o = model.options
        o.showPackageContents.toggle()
        model.setOptions(o)
    }

    @IBAction func showFreeSpace(_ sender: Any?) {
        var o = model.options
        o.showFreeSpace.toggle()
        model.setOptions(o)
    }

    @IBAction func showOtherSpace(_ sender: Any?) {
        var o = model.options
        o.showOtherSpace.toggle()
        model.setOptions(o)
    }

    @IBAction func showPhysicalSizes(_ sender: Any?) {
        var o = model.options
        o.sizeMode = o.sizeMode == .allocated ? .logical : .allocated
        model.setOptions(o)
    }

    @IBAction func changeSplitting(_ sender: Any?) {
        filesSplit.isVertical.toggle()
        UserDefaults.standard.set(!filesSplit.isVertical, forKey: "SplitWindowHorizontally")
        let total = filesSplit.isVertical ? filesSplit.bounds.width : filesSplit.bounds.height
        filesSplit.adjustSubviews()
        filesSplit.setPosition((total * 0.4).rounded(), ofDividerAt: 0)
    }

    @IBAction func showInformationPanel(_ sender: Any?) {
        let info = InfoPanelController.shared
        if info.isVisible { info.hide() } else { info.show(model.selection.map { (model, $0) }) }
    }

    // MARK: trash and refresh

    private(set) var isBusy = false

    @IBAction func moveToTrash(_ sender: Any?) {
        guard let node = model.selection, node != model.zoomedNode, node != Snapshot.root, !isBusy, let window else { return }
        let s = model.snapshot
        let name = s.name(of: node)
        let alert = NSAlert()
        alert.messageText = "Move “\(name)” to the Trash?"
        let size = Format.size(s.allocatedSize[node])
        var info = s.isDirectory(node)
            ? "The folder and the \(Format.count(Self.itemCount(s, node))) items in it use \(size) on disk."
            : "It uses \(size) on disk."
        info += " You can put it back from the Trash."
        alert.informativeText = info
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performTrash(node)
        }
    }

    static func itemCount(_ s: Snapshot, _ node: NodeIndex) -> Int {
        var count = 0
        var stack = [node]
        while let n = stack.popLast() {
            let r = s.children(of: n)
            count += r.count
            stack.append(contentsOf: r)
        }
        return count
    }

    /// Moves a node's file to the Trash and takes it out of the snapshot
    /// (no rescan). `trash` is the file operation (replaceable in tests).
    func performTrash(_ node: NodeIndex, trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        let s = model.snapshot
        let url = URL(fileURLWithPath: s.path(of: node))
        let rect = (window?.firstResponder === outline.outlineView ? outline.selectedRowRect.map { outline.outlineView.convert($0, to: nil) } : nil)
            ?? treemapView.rect(for: node).map { treemapView.convert($0, to: nil) }
        do {
            try trash(url)
        } catch {
            if let window {
                let alert = NSAlert()
                alert.messageText = "“\(s.name(of: node))” can’t be moved to the Trash."
                alert.informativeText = (error as NSError).localizedDescription
                alert.beginSheetModal(for: window)
            }
            return
        }
        let (snapshot, map) = SnapshotEdits.removing(s, [node])
        model.replaceSnapshot(snapshot, indexMap: map)
        if let rect, let window, window.isVisible {
            let p = window.convertPoint(toScreen: NSPoint(x: rect.midX, y: rect.midY))
            NSAnimationEffect.poof.show(centeredAt: p, size: .zero)
        }
    }

    /// Refresh: rescans the selected folder (a file: its folder) and splices it in.
    @IBAction func refresh(_ sender: Any?) {
        guard var node = model.selection, !isBusy else { return }
        let s = model.snapshot
        if !s.isDirectory(node) { node = Int(s.parent[node]) }
        refreshFolder(node)
    }

    @IBAction func refreshAll(_ sender: Any?) {
        guard !isBusy else { return }
        refreshFolder(Snapshot.root)
    }

    func refreshFolder(_ node: NodeIndex) {
        let s = model.snapshot
        let path = s.path(of: node)
        guard FileManager.default.fileExists(atPath: path) else {
            if node == Snapshot.root { return }
            // gone: take it out
            let (snapshot, map) = SnapshotEdits.removing(s, [node])
            model.replaceSnapshot(snapshot, indexMap: map)
            return
        }
        isBusy = true
        let op = ScanOperation(url: URL(fileURLWithPath: path))
        op.start(sheetOn: window) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            switch result {
            case .success(let scan):
                self.applyRefresh(scan, at: node, rootPath: s.rootPath, scannedPath: path, before: s)
            case .failure(let error):
                if let window = self.window { self.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil) }
            }
            self.window?.toolbar?.validateVisibleItems()
        }
        // if the user cancels, isBusy is reset by the panel closing
        op.progressPanel.onCancel = { [weak self, weak op] in op?.cancel(); self?.isBusy = false }
    }

    func applyRefresh(_ scan: ScanResult, at node: NodeIndex, rootPath: String, scannedPath: String, before: Snapshot) {
        // the snapshot may have changed meanwhile; find the folder again
        let current = model.snapshot
        let target = current.nodeCount == before.nodeCount && current.scanDate == before.scanDate ? node
            : current.findNode(path: scannedPath)
        guard let target else { return }
        if target == Snapshot.root {
            var fresh = scan.snapshot
            fresh.rootPath = current.rootPath
            model.replaceSnapshot(fresh, indexMap: nil)
        } else {
            let (snapshot, map) = SnapshotEdits.replacingSubtree(current, at: target, with: scan.snapshot)
            model.replaceSnapshot(snapshot, indexMap: map)
        }
        if scan.summary.unreadableFolders > 0 { showUnreadableNotice(scan.summary.unreadableFolders) }
        else if scanDocument?.isSavedScan == true && target == Snapshot.root { hideNotice() }
    }
}
