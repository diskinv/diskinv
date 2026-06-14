//
//  MainWindowController.swift
//  Disk Inventory Xs
//
//  Swift port of MainWindowController.{h,m}. Top-level coordinator for a
//  scanned document window: menu/toolbar actions (zoom, trash, view options),
//  UI validation, the "Open With" submenu, the kinds/selection drawers, and
//  service-menu support. Subclass of OAToolbarWindowControllerEx.
//
//  GPL v3
//

import Cocoa

@objc(MainWindowController)
class MainWindowController: OAToolbarWindowControllerEx {

    @IBOutlet private var _kindsDrawer: NSDrawer!
    @IBOutlet private var _selectionListDrawer: NSDrawer!
    @IBOutlet private var _splitter: NSSplitView!
    @IBOutlet private var _filesOutlineView: NSOutlineView!
    @IBOutlet private var _treeMapView: TreeMapView!
    @IBOutlet private var _openWithSubMenu: NSMenu!

    // registered once, before the first window's nib loads
    private static let registerServicesOnce: Void = {
        NSApp.registerServicesMenuSendTypes([NSPasteboard.PasteboardType("NSFilenamesPboardType")],
                                            returnTypes: [])
    }()

    private func fsDocument() -> FileSystemDoc? { document as? FileSystemDoc }

    override func windowWillLoad() {
        // bindings in the nib use this transformer, so register it before load
        ValueTransformer.setValueTransformer(FileSizeTransformer.transformer(),
                                             forName: NSValueTransformerName("fileSizeTransformer"))
        _ = Self.registerServicesOnce
        super.windowWillLoad()
    }

    @objc(documentForView:)
    class func documentForView(_ view: NSView) -> FileSystemDoc? {
        // the window's delegate is the window controller, whose document is ours
        (view.window?.delegate as? NSWindowController)?.document as? FileSystemDoc
    }

    @objc(poofEffectInView:inRect:)
    class func poofEffect(in view: NSView, inRect rect: NSRect) {
        // center the poof in the rect
        var poofPoint = NSPoint(x: rect.minX + rect.width / 2, y: rect.minY + rect.height / 2)
        poofPoint = view.convert(poofPoint, to: nil)             // view -> window
        poofPoint = view.window?.convertPoint(toScreen: poofPoint) ?? poofPoint  // window -> screen

        var size = NSSize(width: rect.width, height: rect.height)
        // not too small, not too large
        if min(size.width, size.height) <= 25 || (size.width + size.height) <= 80 {
            size = .zero  // default size
        }
        size.width = min(size.width, 200)
        size.height = min(size.height, 200)

        NSAnimationEffect.poof.show(centeredAt: poofPoint, size: size, completionHandler: {})
    }

    override func awakeFromNib() {
        if UserDefaults.standard.bool(forKey: SplitWindowHorizontally) {
            _splitter.isVertical = false
        }
        _splitter.autosaveName = "MainWindowSplitter"
        _kindsDrawer.toggle(self)
    }

    @objc func kindStatisticsDrawer() -> NSDrawer { _kindsDrawer }
    @objc func selectionListDrawer() -> NSDrawer { _selectionListDrawer }

    // MARK: - menu and toolbar actions

    @IBAction func toggleFileKindsDrawer(_ sender: Any?) { _kindsDrawer.toggle(self) }
    @IBAction func toggleSelectionListDrawer(_ sender: Any?) { _selectionListDrawer.toggle(self) }

    @IBAction func openFile(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else { return }
        guard let itemURL = fsDocument()?.selectedItem()?.fileURL() else { return }
        var appURL = menuItem.representedObject as? NSURL
        if appURL == nil {
            appURL = AppsForItem.appsForItem(itemURL).defaultAppURL
        }
        if let appURL = appURL {
            AppsForItem.openItem(url: itemURL, withAppURL: appURL)
        }
    }

    @IBAction func zoomIn(_ sender: Any?) {
        guard let doc = fsDocument(), let selectedItem = doc.selectedItem(), selectedItem.isFolder() else { return }
        doc.zoomIntoItem(selectedItem)
        synchronizeWindowTitleWithDocumentName()
    }

    @IBAction func zoomOut(_ sender: Any?) {
        guard let doc = fsDocument() else { return }
        let currentZoomedItem = doc.zoomedItem()
        if currentZoomedItem !== doc.rootItem() {
            doc.zoomOutOneStep()
            if let currentZoomedItem = currentZoomedItem { doc.setSelectedItem(currentZoomedItem) }
            synchronizeWindowTitleWithDocumentName()
        }
    }

    @IBAction func zoomOutTo(_ sender: Any?) {
        guard let doc = fsDocument(), let item = (sender as? NSMenuItem)?.representedObject as? FSItem else { return }
        let currentZoomedItem = doc.zoomedItem()
        doc.zoomOut(toItem: item)
        if let currentZoomedItem = currentZoomedItem { doc.setSelectedItem(currentZoomedItem) }
        synchronizeWindowTitleWithDocumentName()
    }

    @IBAction func showInFinder(_ sender: Any?) {
        guard let selectedItem = fsDocument()?.selectedItem(), selectedItem.exists() else { return }
        NSWorkspace.shared.selectFile(selectedItem.path(), inFileViewerRootedAtPath: "")
    }

    @IBAction func refresh(_ sender: Any?) {
        guard let doc = fsDocument(), let selectedItem = doc.selectedItem() else { return }
        doc.refreshItem(selectedItem)
        synchronizeWindowTitleWithDocumentName()
    }

    @IBAction func refreshAll(_ sender: Any?) {
        fsDocument()?.refreshItem(nil)
        synchronizeWindowTitleWithDocumentName()
    }

    @IBAction func moveToTrash(_ sender: Any?) {
        guard let doc = fsDocument(), let selectedItem = doc.selectedItem(),
              selectedItem !== doc.zoomedItem(), !selectedItem.isSpecialItem() else { return }

        // items on network volumes are deleted, not trashed, so warn first
        if selectedItem.fileURL()?.isLocalVolume() != true {
            let msg = String(format: NSLocalizedString("The item \"%@\" could not be moved to the trash.", comment: ""),
                             selectedItem.displayName())
            let alert = NSAlert()
            alert.messageText = msg
            alert.informativeText = NSLocalizedString("Would you like to delete it immediately?", comment: "")
            alert.addButton(withTitle: NSLocalizedString("No", comment: ""))   // first
            alert.addButton(withTitle: NSLocalizedString("Yes", comment: ""))  // second
            alert.beginSheetModal(for: window!) { [weak self] returnCode in
                self?.moveToTrashSheetDidDismiss(returnCode: returnCode, item: selectedItem)
            }
        } else {
            moveToTrashSheetDidDismiss(returnCode: .alertSecondButtonReturn, item: selectedItem)
        }
    }

    @IBAction func showPackageContents(_ sender: Any?) {
        guard let doc = fsDocument() else { return }
        doc.setShowPackageContents(!doc.showPackageContents())
    }

    @IBAction func showFreeSpace(_ sender: Any?) {
        guard let doc = fsDocument() else { return }
        doc.setShowFreeSpace(!doc.showFreeSpace())
    }

    @IBAction func showOtherSpace(_ sender: Any?) {
        guard let doc = fsDocument() else { return }
        doc.setShowOtherSpace(!doc.showOtherSpace())
    }

    @IBAction func selectParentItem(_ sender: Any?) {
        guard let doc = fsDocument(), let selectedItem = doc.selectedItem() else { return }
        // don't go above the zoomed item or its direct children
        if selectedItem !== doc.zoomedItem() && selectedItem.parent() !== doc.zoomedItem() {
            doc.setSelectedItem(selectedItem.parent())
        }
    }

    @IBAction func changeSplitting(_ sender: Any?) {
        _splitter.isVertical = !_splitter.isVertical
        window?.contentView?.needsDisplay = true
    }

    @IBAction func showInformationPanel(_ sender: Any?) {
        guard let infoController = InfoPanelController.shared() else { return }
        if infoController.panelIsVisible() {
            infoController.hidePanel()
        } else {
            infoController.showPanel(with: fsDocument()?.selectedItem())
        }
    }

    @IBAction func showPhysicalSizes(_ sender: Any?) {
        guard let doc = fsDocument() else { return }
        doc.setShowPhysicalFileSize(!doc.showPhysicalFileSize())
        synchronizeWindowTitleWithDocumentName()
    }

    @IBAction func ignoreCreatorCode(_ sender: Any?) {
        guard let doc = fsDocument() else { return }
        doc.setIgnoreCreatorCode(!doc.ignoreCreatorCode())
    }

    @IBAction func performRenderBenchmark(_ sender: Any?) {
        let startTime = getTime()
        let count: UInt32 = 20
        _treeMapView.benchmarkRendering(withImageSize: NSSize(width: 1024, height: 768), count: count)
        let doneTime = getTime()
        let msg = String(format: "rendering %u times took %.2f seconds", count, subtractTime(doneTime, startTime))
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = msg
        alert.beginSheetModal(for: _splitter.window!, completionHandler: nil)
    }

    @IBAction func performLayoutBenchmark(_ sender: Any?) {
        let startTime = getTime()
        let count: UInt32 = 100
        _treeMapView.benchmarkLayoutCalculation(withImageSize: NSSize(width: 1024, height: 768), count: count)
        let doneTime = getTime()
        let msg = String(format: "layout calculation %u times took %.2f seconds", count, subtractTime(doneTime, startTime))
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = msg
        alert.beginSheetModal(for: _splitter.window!, completionHandler: nil)
    }

    // MARK: - UI element validation

    // The single per-command decision, applied by the base class to either a
    // menu item or a toolbar item (see OAToolbarWindowControllerEx).
    override func commandValidation(forAction menuAction: Selector?) -> CommandValidation {
        let doc = fsDocument()
        let selectedItem = doc?.selectedItem()

        // a toggle: title flips, and a toolbar button shows the inverse on/off icon
        // (matching the original setState: cond ? .off : .on)
        func toggle(_ cond: Bool, _ whenOn: String, _ whenOff: String) -> CommandValidation {
            CommandValidation(title: cond ? whenOn : whenOff, toolbarState: cond ? .off : .on)
        }
        // a title-only toggle (no toolbar icon swap)
        func titleToggle(_ cond: Bool, _ s1: String, _ s2: String) -> CommandValidation {
            CommandValidation(title: cond ? s1 : s2)
        }

        if menuAction == #selector(openFile(_:)) || menuAction == NSSelectorFromString("openFileWith:") {
            guard let url = selectedItem?.fileURL() else { return CommandValidation(isEnabled: false) }
            return CommandValidation(isEnabled: AppsForItem.appsForItem(url).defaultAppURL != nil)
        } else if menuAction == #selector(zoomIn(_:)) {
            return CommandValidation(isEnabled: selectedItem != nil && selectedItem!.isFolder() && !_treeMapView.zoomingInProgress())
        } else if menuAction == #selector(zoomOut(_:)) {
            return CommandValidation(isEnabled: doc?.rootItem() !== doc?.zoomedItem() && !_treeMapView.zoomingInProgress())
        } else if menuAction == #selector(showInFinder(_:)) || menuAction == #selector(refresh(_:)) {
            return CommandValidation(isEnabled: selectedItem != nil)
        } else if menuAction == #selector(moveToTrash(_:)) {
            var residesInTrash = false
            if let selectedURL = selectedItem?.fileURL() {
                if let trashURL = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                               appropriateFor: selectedURL as URL, create: false) {
                    residesInTrash = selectedURL.isEqual(to: trashURL as NSURL) || selectedURL.residesInDirectory(trashURL as NSURL)
                }
            }
            return CommandValidation(isEnabled: !residesInTrash && selectedItem != nil && selectedItem !== doc?.zoomedItem() && !(selectedItem!.isSpecialItem()))
        } else if menuAction == #selector(showPackageContents(_:)) {
            return toggle(doc?.showPackageContents() ?? false, "Hide Package Contents", "Show Package Contents")
        } else if menuAction == #selector(showFreeSpace(_:)) {
            return toggle(doc?.showFreeSpace() ?? false, "Hide Free Space", "Show Free Space")
        } else if menuAction == #selector(showOtherSpace(_:)) {
            var v = toggle(doc?.showOtherSpace() ?? false, "Hide Other Space", "Show Other Space")
            if doc?.zoomedItem()?.fileURL()?.isVolume() == true { v.isEnabled = false }
            return v
        } else if menuAction == #selector(showPhysicalSizes(_:)) {
            return toggle(doc?.showPhysicalFileSize() ?? false, "Show Logical File Size", "Show Physical File Size")
        } else if menuAction == #selector(ignoreCreatorCode(_:)) {
            return toggle(doc?.ignoreCreatorCode() ?? false, "Respect Creator Code", "Ignore Creator Code")
        } else if menuAction == #selector(toggleFileKindsDrawer(_:)) {
            return toggle(_kindsDrawer.state == 0, "Show File Kind Statistics", "Hide File Kind Statistics")  // 0 == NSDrawerClosedState
        } else if menuAction == #selector(toggleSelectionListDrawer(_:)) {
            return titleToggle(_selectionListDrawer.state == 0, "Show Selection List", "Hide Selection List")  // 0 == NSDrawerClosedState
        } else if menuAction == #selector(selectParentItem(_:)) {
            return CommandValidation(isEnabled: selectedItem != nil && selectedItem !== doc?.zoomedItem())
        } else if menuAction == #selector(showInformationPanel(_:)) {
            return toggle(InfoPanelController.shared()?.panelIsVisible() ?? false, "Hide Information", "Show Information")
        } else if menuAction == #selector(changeSplitting(_:)) {
            return titleToggle(_splitter.isVertical, "Split Horizontally", "Split Vertically")
        }

        return CommandValidation()
    }

    // MARK: - Toolbar support

    // selects which .toolbar config the base loads
    override var toolbarConfigurationName: String { "MainWindowToolbar" }

    // MARK: - NSWindow delegate

    func windowDidBecomeMain(_ notification: Notification) {
        if InfoPanelController.shared()?.panelIsVisible() == true {
            InfoPanelController.shared()?.showPanel(with: fsDocument()?.selectedItem())
        }
    }

    func windowDidResignMain(_ notification: Notification) {}

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow)?.isMainWindow == true,
           InfoPanelController.shared()?.panelIsVisible() == true {
            InfoPanelController.shared()?.showPanel(with: nil)
        }
    }

    // MARK: - NSMenu delegate (populates the "Open With" submenu)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let itemURL = fsDocument()?.selectedItem()?.fileURL() else { return }

        let apps = AppsForItem.appsForItem(itemURL)

        // Rebuild the submenu from scratch: when there is a default app, the
        // items are [default app, separator, additional apps...]; otherwise the
        // submenu is empty (nothing can open the file).
        var items: [NSMenuItem] = []
        if let defaultAppURL = apps.defaultAppURL {
            items.append(makeOpenWithItem(appURL: defaultAppURL))   // item 0: default app
            items.append(NSMenuItem.separator())                    // item 1: separator
            for appURL in apps.additionalAppURLs {
                items.append(makeOpenWithItem(appURL: appURL))
            }
        }
        _openWithSubMenu.items = items
    }

    private func makeOpenWithItem(appURL: NSURL) -> NSMenuItem {
        let menuItem = NSMenuItem()
        configureOpenWith(menuItem, appURL: appURL)
        return menuItem
    }

    private func configureOpenWith(_ menuItem: NSMenuItem, appURL: NSURL) {
        menuItem.title = appURL.displayName()
        menuItem.toolTip = appURL.displayPath()
        menuItem.representedObject = appURL
        menuItem.target = self
        menuItem.action = #selector(openFile(_:))
        let icon = appURL.icon()
        icon?.size = NSSize(width: 16, height: 16)
        menuItem.image = icon
    }

    // MARK: - service menu support

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        let selectedItem = fsDocument()?.selectedItem()
        if let selectedItem = selectedItem,
           !selectedItem.isSpecialItem(),
           (returnType?.rawValue ?? "").isEmpty,   // we accept no input
           selectedItem.exists(),
           selectedItem.supportsPasteboardType(sendType?.rawValue ?? "") {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    @objc(writeSelectionToPasteboard:types:)
    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let item = fsDocument()?.selectedItem(), !item.isSpecialItem() else { return false }
        item.writeToPasteboard(pboard, withTypes: types)
        return true
    }

    // MARK: - private

    private func moveToTrashSheetDidDismiss(returnCode: NSApplication.ModalResponse, item selectedItem: FSItem) {
        guard returnCode == .alertSecondButtonReturn else { return }
        guard let doc = fsDocument() else { return }

        assert(selectedItem !== doc.zoomedItem() && !selectedItem.isSpecialItem())

        // compute the poof position before deleting
        let cellRect: NSRect
        let view: NSView
        if window?.firstResponder === _filesOutlineView {
            view = _filesOutlineView
            cellRect = _filesOutlineView.frameOfCell(atColumn: 0, row: _filesOutlineView.selectedRow)
        } else {
            view = _treeMapView
            cellRect = _treeMapView.itemRectByPath(toItem: selectedItem.fsItemPath(fromAncestor: doc.zoomedItem()) as [Any])
        }

        do {
            try doc.moveItemToTrash(selectedItem)
            Self.poofEffect(in: view, inRect: cellRect)
            synchronizeWindowTitleWithDocumentName()
        } catch {
            let msg = String(format: NSLocalizedString("\"%@\" cannot be moved to the trash by Disk Inventory X.", comment: ""),
                             selectedItem.displayName())
            let failAlert = NSAlert()
            failAlert.alertStyle = .informational
            failAlert.messageText = msg
            failAlert.informativeText = (error as NSError).localizedFailureReason ?? ""
            failAlert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            failAlert.beginSheetModal(for: window!, completionHandler: nil)
        }
    }
}
