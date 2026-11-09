//
//  TreeMapViewController.swift
//  Disk Inventory Xs
//
//  Swift port of TreeMapViewController.{h,m}. Data source + delegate for the
//  TreeMapView: vends the FSItem tree (plus the synthetic free/other-space
//  items at the root), colors each cushion by file kind, drives selection both
//  ways, and animates zoom. TreeMapView (the NSView and its renderer) stays
//  Objective-C and is reached via the bridging header; its data source/delegate
//  are informal protocols dispatched dynamically, so the methods just need
//  matching @objc selectors. Nib-wired, so the class name and outlets carry
//  @objc.
//
//  GPL v3
//

import Cocoa

@objc(TreeMapViewController)
class TreeMapViewController: NSObject {

    @IBOutlet private var _fileNameTextField: NSTextField!
    @IBOutlet private var _fileSizeTextField: NSTextField!
    @IBOutlet private var _treeMapView: TreeMapView!
    @IBOutlet private var _document: FileSystemDoc!

    private var _otherSpaceItem: FSItem?
    private var _freeSpaceItem: FSItem?

    private static var shareKindColorsContext = 0

    override func awakeFromNib() {
        let doc = document()
        let center = NotificationCenter.default

        center.addObserver(self, selector: #selector(zoomedItemChanged(_:)),
                           name: NSNotification.Name.ZoomedItemChanged, object: doc)
        center.addObserver(self, selector: #selector(viewOptionChanged(_:)),
                           name: NSNotification.Name.ViewOptionChanged, object: doc)
        center.addObserver(self, selector: #selector(itemsChanged(_:)),
                           name: NSNotification.Name.FSItemsChanged, object: doc)
        center.addObserver(self, selector: #selector(windowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: _treeMapView?.window)

        _fileNameTextField?.stringValue = ""
        _fileSizeTextField?.stringValue = ""

        doc?.addObserver(self, forKeyPath: DocKeySelectedItem, options: .new, context: nil)
        NSUserDefaultsController.shared.addObserver(self, forKeyPath: "values." + ShareKindColors,
                                                    options: [], context: &Self.shareKindColorsContext)

        // create the synthetic "free space" / "other space" items
        // (use the real root, not the zoomed item)
        if let rootItem = doc?.rootItem() {
            _otherSpaceItem = FSItem(asOtherSpaceItemForParent: rootItem)
            _freeSpaceItem = FSItem(asFreeSpaceItemForParent: rootItem)
        }

        reloadData()
    }

    @objc func document() -> FileSystemDoc? {
        if _document == nil, let view = _treeMapView {
            // mirror MainWindowController.documentForView:
            _document = (view.window?.delegate as? NSWindowController)?.document as? FileSystemDoc
        }
        return _document
    }

    @objc func rootItem() -> FSItem? {
        document()?.zoomedItem()
    }

    // MARK: - TreeMapView data source

    @objc func treeMapView(_ view: TreeMapView!, child index: UInt, ofItem item: Any!) -> Any! {
        let fsItem = (item as? FSItem) ?? rootItem()

        if fsItem === rootItem(), let fsItem = fsItem, index >= fsItem.childCount() {
            if index - fsItem.childCount() == 0 {
                return (document()?.showOtherSpace() ?? false) ? _otherSpaceItem : _freeSpaceItem
            }
            return _freeSpaceItem
        }
        return fsItem?.child(at: index)
    }

    @objc func treeMapView(_ view: TreeMapView!, isNode item: Any!) -> Bool {
        guard let fsItem = (item as? FSItem) ?? rootItem() else { return false }
        return !fsItem.isSpecialItem() && (document()?.itemIsNode(fsItem) ?? false)
    }

    @objc func treeMapView(_ view: TreeMapView!, numberOfChildrenOfItem item: Any!) -> UInt32 {
        let fsItem = (item as? FSItem) ?? rootItem()
        var childCount = fsItem?.childCount() ?? 0

        // the synthetic other/free space items live under the root
        if fsItem === rootItem(), let doc = document() {
            if doc.showFreeSpace() { childCount += 1 }
            if doc.showOtherSpace() { childCount += 1 }
        }
        return UInt32(childCount)
    }

    @objc func treeMapView(_ view: TreeMapView!, weightByItem item: Any!) -> UInt64 {
        let fsItem = (item as? FSItem) ?? rootItem()
        var size = fsItem?.sizeValue() ?? 0

        if fsItem === rootItem(), let doc = document() {
            if doc.showFreeSpace() { size += _freeSpaceItem?.sizeValue() ?? 0 }
            if doc.showOtherSpace() { size += _otherSpaceItem?.sizeValue() ?? 0 }
        }
        return size
    }

    // MARK: - TreeMapView delegate

    @objc func treeMapView(_ view: TreeMapView!, getToolTipByItem item: Any!) -> String! {
        let fsItem = (item as? FSItem) ?? rootItem()
        return fsItem?.displayName()
    }

    @objc func treeMapView(_ view: TreeMapView!, willDisplayItem item: Any!, withRenderer renderer: TMVItem!) {
        let fsItem = (item as? FSItem) ?? rootItem()

        var color: NSColor?
        let type = fsItem?.type()
        if type == FileFolderItem {
            color = fsItem.flatMap { document()?.fileTypeColors().color(forItem: $0) }
        } else if type == FreeSpaceItem {
            color = TMVCushionRenderer.normalize(NSColor(calibratedWhite: 1, alpha: 1))
        } else if type == OtherSpaceItem {
            color = TMVCushionRenderer.normalize(NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        }

        renderer.setCushionColor(color)
    }

    @objc(treeMapView:willShowMenuForEvent:)
    func treeMapView(_ view: TreeMapView!, willShowMenuFor event: NSEvent!) {
        guard event.type == .rightMouseDown else { return }

        // select the item under the click so the user sees which item the menu is for
        let point = event.locationInWindow
        guard let cell = _treeMapView.cellId(by: point, inViewCoords: false) else { return }
        let fsItem = _treeMapView.item(byCellId: cell) as? FSItem

        if let fsItem = fsItem, !fsItem.isSpecialItem() {
            document()?.setSelectedItem(fsItem)
        }
        onDocumentSelectionChanged()
    }

    // MARK: - TreeMapView notifications (auto-registered by the view via respondsToSelector)

    @objc func treeMapViewItemTouched(_ notification: Notification!) {
        let fsItem = notification.userInfo?[TMVTouchedItem] as? FSItem

        guard let fsItem = fsItem else {
            _fileNameTextField.stringValue = ""
            _fileSizeTextField.stringValue = ""
            return
        }

        var displayName = fsItem.displayName()
        let sizeFormatter = FileSizeFormatter()
        let size = sizeFormatter.string(for: fsItem.size()) ?? ""

        // a cell standing for many small items merged together (fsItem is their folder)
        if let mergedCount = notification.userInfo?[TMVTouchedMergedItemCount] as? Int,
           let mergedSize = notification.userInfo?[TMVTouchedMergedItemSize] as? NSNumber {
            let mergedSizeString = sizeFormatter.string(for: mergedSize) ?? ""
            _fileNameTextField.stringValue = String(
                format: NSLocalizedString("%ld small items in %@", comment: "treemap cell of merged small items"),
                mergedCount, displayName)
            _fileSizeTextField.stringValue = mergedSizeString
            return
        }

        if !fsItem.isSpecialItem() {
            displayName += " (\(fsItem.displayFolderName()))"
            _fileSizeTextField.stringValue = "\(fsItem.kindName()), \(size)"
        } else {
            _fileSizeTextField.stringValue = size
        }
        _fileNameTextField.stringValue = displayName
    }

    @objc func treeMapViewSelectionDidChange(_ notification: Notification!) {
        let item = _treeMapView.selectedItem() as? FSItem
        let doc = document()

        // Selecting a file that is too small to draw highlights its folder's
        // merged small-items cell, whose item is the folder. Don't let that
        // echo replace the selected file with the folder.
        if let cell = _treeMapView.selectedCellId(), cell.isSmallItemsCell,
           let folder = item, let selected = doc?.selectedItem(),
           selected !== folder, selected.isDescendant(of: folder) {
            return
        }

        // ignore the echo of a selection we set ourselves (onDocumentSelectionChanged)
        if doc?.selectedItem() !== item, !(item?.isSpecialItem() ?? false) {
            doc?.setSelectedItem(item)
        }
    }

    // MARK: - document notifications

    @objc private func itemsChanged(_ notification: Notification) {
        if let rootItem = document()?.rootItem() {
            _otherSpaceItem = FSItem(asOtherSpaceItemForParent: rootItem)
            _freeSpaceItem = FSItem(asFreeSpaceItemForParent: rootItem)
        }
        reloadData()
    }

    @objc private func zoomedItemChanged(_ notification: Notification) {
        if !UserDefaults.standard.bool(forKey: AnimatedZooming) {
            reloadData()
            return
        }

        guard let oldZoomedItem = notification.userInfo?[OldItem] as? FSItem,
              let newZoomedItem = notification.userInfo?[NewItem] as? FSItem else {
            reloadData()
            return
        }
        assert(newZoomedItem === rootItem(), "invalid new zoomed item")

        if newZoomedItem.isDescendant(of: oldZoomedItem) {
            _treeMapView.reloadAndPerformZoom(intoItem: newZoomedItem.fsItemPath(fromAncestor: oldZoomedItem))
        } else {
            _treeMapView.reloadAndPerformZoomOutofItem(oldZoomedItem.fsItemPath(fromAncestor: newZoomedItem))
        }
    }

    @objc private func viewOptionChanged(_ notification: Notification) {
        let option = notification.userInfo?[ChangedViewOption] as? String
        if option == ShowPackageContents || option == ShowPhysicalFileSize
            || option == IgnoreCreatorCode || option == ShowOtherSpace || option == ShowFreeSpace {
            reloadData()
            onDocumentSelectionChanged()
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        document()?.removeObserver(self, forKeyPath: DocKeySelectedItem)
        NotificationCenter.default.removeObserver(self)
        NSUserDefaultsController.shared.removeObserver(self, forKeyPath: "values." + ShareKindColors)
    }

    // MARK: - KVO

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if context == &Self.shareKindColorsContext {
            _treeMapView.invalidateCanvasCache()
            _treeMapView.needsDisplay = true
        } else if object as AnyObject === document(), keyPath == DocKeySelectedItem {
            onDocumentSelectionChanged()
        }
    }

    // MARK: - private

    private func onDocumentSelectionChanged() {
        let item = document()?.selectedItem()
        if item === (_treeMapView.selectedItem() as? FSItem) { return }

        if item == nil {
            _treeMapView.selectItem(byCellId: nil)
        } else {
            _treeMapView.selectItemByPath(toItem: item!.fsItemPath(fromAncestor: rootItem()))
        }
    }

    private func reloadData() {
        _treeMapView.reloadData()
        onDocumentSelectionChanged()
    }
}
