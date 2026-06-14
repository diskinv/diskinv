//
//  FileSystemDoc.swift
//  Disk Inventory X
//
//  Swift port of the document class FileSystemDoc (formerly
//  FileSystemDoc.h/.m). The NSDocument subclass that owns the scanned
//  file-system tree (root FSItem), the zoom stack, the per-kind
//  statistics, the view options, and the kind colors. ARC throughout.
//
//  The KVO key / notification-name extern string constants live in the
//  macro-clean ObjC FileSystemDocSupport.h/.m (extern C strings cannot be
//  defined in Swift) and are visible here via the bridging header.
//
//  Scan cancellation now flows through the Swift FSItemError thrown by
//  FSItem.loadChildren() (see FSItem.swift), caught with do/catch here —
//  replacing the former NSException @try/@catch (which Swift cannot use).
//
//  GPL v3
//

import Cocoa

@objc(FileSystemDoc)
class FileSystemDoc: NSDocument, FSItemDelegate {

    //MARK: ivars

    private var _rootItem: FSItem?
    //KVO-observed by the controllers via key path "selectedItem"
    //(DocKeySelectedItem). `dynamic` makes it KVO-compliant.
    @objc dynamic private var _selectedItem: FSItem?
    //Private backing storage: native Swift array. The public zoomStack() getter
    //bridges to NSArray to preserve its KVC/binding-visible return type. (The
    //original NSMutableArray was mutated in place without KVO notifications, so
    //reassigning the Swift array preserves the exact notification behavior.)
    private var _zoomStack: [FSItem] = []
    //Private backing storage: native Swift dictionary (kind name ->
    //FileKindStatistic). The public kindStatistics() getter bridges to
    //NSDictionary to preserve its KVC/binding-visible return type.
    private var _fileKindStatistics: [String: FileKindStatistic] = [:]
    private var _viewOptions: NSMutableDictionary = NSMutableDictionary.dictionaryWithDefaults()
    private var _kindColors: FileTypeColors?

    //these variables are used during the initial directory scan
    private var _progressController: LoadingPanelController?
    //Private transient scan state: stack of folders during the progress scan.
    private var _directoryStack: [FSItem]?

    //context pointer for the ShareKindColors user-defaults observation
    private static var shareKindColorsContext = 0

    //MARK: lifecycle

    override class var autosavesInPlace: Bool {
        return false
    }

    override init() {
        super.init()

        let sharedDefsController = NSUserDefaultsController.shared
        sharedDefsController.addObserver(self,
                                         forKeyPath: "values." + ShareKindColors,
                                         options: [],
                                         context: &FileSystemDoc.shareKindColorsContext)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        let sharedDefsController = NSUserDefaultsController.shared
        sharedDefsController.removeObserver(self,
                                            forKeyPath: "values." + ShareKindColors,
                                            context: &FileSystemDoc.shareKindColorsContext)
    }

    override func makeWindowControllers() {
        //MainWindowController is ObjC; its header pulls in non-macro-clean
        //dependencies, so it is not in the bridging header. Instantiate it via
        //the runtime (NSWindowController initWithWindowNibName:).
        guard let cls = NSClassFromString("MainWindowController") as? NSWindowController.Type else {
            assertionFailure("MainWindowController class not found")
            return
        }
        let controller = cls.init(windowNibName: self.windowNibName!)
        addWindowController(controller)
    }

    override var windowNibName: NSNib.Name? {
        return "TreeMap"
    }

    override func windowControllerDidLoadNib(_ aController: NSWindowController) {
        super.windowControllerDidLoadNib(aController)
    }

    //MARK: scanning

    //The ObjC original overrode the deprecated -readFromFile:ofType:; keep
    //overriding the same entry point so the document-loading behavior is
    //identical.
    override func read(from url: URL, ofType typeName: String) throws {
        if !readFromFolder(url.path, ofType: typeName) {
            //match the original's behavior: a failed/canceled load aborts the open.
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: nil)
        }
    }

    private func readFromFolder(_ folder: String, ofType docType: String) -> Bool {
        checkForProtectedFolders(folder)

        //now the real work: loading the folder contents
        do {
            g_fileCount = 0
            g_folderCount = 0

            _progressController = LoadingPanelController()
            _progressController?.startAnimation()

            let rootItem = FSItem(path: folder)
            _rootItem = rootItem
            if rootItem.fileURL()?.stillExists() != true {
                _rootItem = nil
                _progressController = nil
                _directoryStack = nil
                return false
            }

            rootItem.setDelegate(self)

            if FSItem.parallelScanEnabled {
                //Parallel path: dispatch the whole scan onto a background queue
                //and keep the main thread pumping the progress panel (so Cancel
                //stays live and the UI never freezes).
                try runParallelScan(rootItem: rootItem)
            } else {
                //Serial path (DIX_PARALLEL_SCAN=0): unchanged inline walk, whose
                //fsItemEnteringFolder: callbacks pump the runloop themselves.
                try rootItem.loadChildren()
            }

            //ok, now we've got an FSItem for every file and directory in the given folder

            //Phase 2 (main thread, unchanged): finalize sizes (incl. OtherSpace
            //via the now-final root size) then collect per-kind statistics.
            //
            //The serial scanner ends loadChildrenSerial with
            //recalculateSize(true, ...) (physical), which both sorts every
            //folder's children by size and re-derives file sizes physically. We
            //reproduce exactly that call here so the parallel result is
            //byte-identical (matching size value AND child ordering).
            if FSItem.parallelScanEnabled {
                rootItem.recalculateSize(true, updateParent: false)
            }

            //collect sizes and file count of all file kinds
            try refreshFileKindStatisticsThrowing()

            //the modal session must be ended in the same section (if no exception occured)
            _progressController = nil
        } catch FSItemError.loadingCanceled {
            //loading canceled by user
            _progressController = nil
            _rootItem = nil
            _directoryStack = nil
            return false
        } catch {
            //error
            _progressController = nil
            _rootItem = nil
            _directoryStack = nil

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = NSLocalizedString("The folder's content could not be loaded.", comment: "")
            alert.informativeText = (error as NSError).localizedDescription
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()

            return false
        }

        _directoryStack = nil

        return true
    }

    @objc(cancelScanningFolder:)
    @IBAction func cancelScanningFolder(_ sender: Any?) {
        NSApplication.shared.stopModal()
    }

    //Drive the parallel phase-1 scan: snapshot the behavior flags on the main
    //thread, dispatch the coordinator+workers onto a background queue, and pump
    //the progress panel here on the main thread at ~5 Hz until the scan finishes
    //(or the user cancels / it errors). Rethrows the scan's error so the
    //existing do/catch in readFromFolder performs the identical tear-down.
    private func runParallelScan(rootItem: FSItem) throws {
        //snapshot delegate-derived flags ONCE on the main thread (workers must
        //not call the delegate). setKindStrings == true mirrors loadChildren().
        let params = rootItem.makeScanParams(setKindStrings: true)
        let progress = ScanProgress()

        //capture the scan's outcome to rethrow on the main thread after join.
        var scanError: Error?

        let scanQueue = DispatchQueue(label: "com.derlien.diskinventoryx.scan.coordinator")
        scanQueue.async {
            do {
                try rootItem.loadChildrenParallel(params: params, progress: progress)
            } catch {
                scanError = error
            }
            //mark finished LAST so the pump loop only exits once scanError is set
            progress.finished = true
        }

        //main-thread pump loop: refresh the panel and watch for Cancel.
        //LoadingPanelController.runEventLoop() self-throttles to ~5 Hz.
        while !progress.finished {
            if let progressController = _progressController {
                progressController.setMessageText(progress.currentPath)
                progressController.runEventLoop()
                if progressController.cancelPressed() {
                    progress.cancelled = true
                }
            }
            //small sleep so we don't spin the CPU between event-loop pumps
            Thread.sleep(forTimeInterval: 0.02)
        }

        //ensure the background block's `progress.finished = true` write (and the
        //scanError write that precedes it) are observed here before we read
        //scanError. group-less join: spin until the queue is drained.
        scanQueue.sync { }

        if let scanError = scanError {
            throw scanError
        }
    }

    //MARK: view options

    @objc func showPhysicalFileSize() -> Bool {
        return viewOptions().showPhysicalFileSize
    }

    @objc(setShowPhysicalFileSize:)
    func setShowPhysicalFileSize(_ show: Bool) {
        viewOptions().showPhysicalFileSize = show

        recalculateTotalSize()
        recalculateFileKindStatisticSizes()

        postViewOptionChangedNotification(forOption: ShowPhysicalFileSize)
    }

    @objc func showPackageContents() -> Bool {
        return viewOptions().showPackageContents
    }

    @objc(setShowPackageContents:)
    func setShowPackageContents(_ showParam: Bool) {
        let show = showParam
        if show == viewOptions().showPackageContents {
            return
        }

        // update kind statistics to reflect the change in view
        viewOptions().showPackageContents = show

        // the package add/remove helpers do not work correctly in all cases,
        // so we just rebuild the whole statistics (slower, but correct)
        refreshFileKindStatistics()

        var selectedItem = self.selectedItem()

        //invalidate current selection, as the selection might be an item in a package
        //(if "show package content" is turned off, files in packages aren't visible any more)
        if !showPackageContents() && selectedItem != nil {
            setSelectedItem(nil)
        }

        postViewOptionChangedNotification(forOption: ShowPackageContents)

        //if "show package contents" is turned off, check if selection is within a package
        //(as the selection got invalid)
        if !showPackageContents() && selectedItem != nil {
            //select its farthest parent which is a package
            var packageItem: FSItem? = nil
            var parentItem = selectedItem?.parent()
            while parentItem != nil && parentItem !== zoomedItem() {
                if parentItem!.isPackage() {
                    packageItem = parentItem
                }
                parentItem = parentItem?.parent()
            }

            selectedItem = packageItem
        }

        //restore selection
        if !showPackageContents() && selectedItem != nil {
            setSelectedItem(selectedItem)
        }
    }

    @objc func showFreeSpace() -> Bool {
        return viewOptions().showFreeSpace
    }

    @objc(setShowFreeSpace:)
    func setShowFreeSpace(_ show: Bool) {
        viewOptions().showFreeSpace = show
        postViewOptionChangedNotification(forOption: ShowFreeSpace)
    }

    @objc func showOtherSpace() -> Bool {
        return viewOptions().showOtherSpace
    }

    @objc(setShowOtherSpace:)
    func setShowOtherSpace(_ show: Bool) {
        viewOptions().showOtherSpace = show
        postViewOptionChangedNotification(forOption: ShowOtherSpace)
    }

    @objc func ignoreCreatorCode() -> Bool {
        return viewOptions().ignoreCreatorCode
    }

    @objc(setIgnoreCreatorCode:)
    func setIgnoreCreatorCode(_ ignoreIt: Bool) {
        /*
        viewOptions().ignoreCreatorCode = ignoreIt
        rootItem().setKindStringIgnoringCreatorCode(ignoreIt, includeChilds: true)
        refreshFileKindStatistics()
        postViewOptionChangedNotification(forOption: IgnoreCreatorCode)
         */
    }

    //helper method; returns YES/NO for packages in dependency of the showPackageContents-Flag
    @objc(itemIsNode:)
    func itemIsNode(_ item: FSItem) -> Bool {
        //the zoomed item is always a node, even if it is a package and "show package contents" is turned off
        //(you can always zoom into packages)
        if item === zoomedItem() {
            return true
        }

        if showPackageContents() {
            return item.isFolder()
        } else {
            return item.isFolder() && !item.isPackage()
        }
    }

    @objc func rootItem() -> FSItem? {
        return _rootItem
    }

    //MARK: item mutation

    @objc(moveItemToTrash:error:)
    func moveItemToTrash(_ item: FSItem) throws {
        assert(item !== zoomedItem() && !item.isSpecialItem(), "can't trash zoomed/special item")

        // file moved to trash (its new URL)
        var newFileInTrash: NSURL? = nil
        // FSItem representing the trash folder
        var trashItem: FSItem? = nil

        //The trash visible to the user only shows trashed files/folders on local volumes,
        //so we delete files/folders on network volumes (like the Finder does).
        if item.fileURL()?.isLocalVolume() == true {
            let fm = FileManager.default

            let trashURL = try? fm.url(for: .trashDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: item.fileURL()! as URL,
                                       create: false)

            if let trashURL = trashURL {
                trashItem = rootItem()?.findItem(byAbsolutePath: trashURL.path, allowAncestors: false)
            }

            // move file/folder to trash
            var resulting: NSURL? = nil
            try fm.trashItem(at: item.fileURL()! as URL, resultingItemURL: &resulting)
            newFileInTrash = resulting
        } else {
            // delete file
            try FileManager.default.removeItem(at: item.fileURL()! as URL)
        }

        //if the selected item should be removed, invalidate our selection
        if selectedItem() === item {
            setSelectedItem(nil)
        }

        // keep data model in sync: remove from folder item, add to trash item, update file kind statistic

        // remove the item from the parent's list
        guard let parent = item.parent() else {
            assertionFailure("root item shouldn't be deletable")
            return
        }

        parent.removeChild(item, updateParent: true)

        //keep kind statistic in sync
        willChangeValue(forKey: "kindStatistics")
        removeItemFromFileKindStatistic(item, includingChilds: true)

        //the user's trash may have been created with the trash operation; if so,
        //we won't see the trashed item, as we are not showing the trash folder currently
        if let trashItem = trashItem, let newFileInTrash = newFileInTrash {
            //keep the size of the trashed item, but associate it with the valid URL
            item.setFileURL(newFileInTrash)

            trashItem.insertChild(item, updateParent: true)

            //keep kind statistic in sync
            addItemToFileKindStatistic(item, includingChilds: true)
        }

        //notify observers of the change
        didChangeValue(forKey: "kindStatistics")

        NotificationCenter.default.post(name: NSNotification.Name.FSItemsChanged, object: self)

        //try to set "parent" as new selection
        if parent !== zoomedItem() {
            setSelectedItem(parent)
        }
    }

    @objc(refreshItem:)
    func refreshItem(_ itemParam: FSItem?) {
        //refresh zoomed item?
        var item = itemParam
        if item == nil {
            item = zoomedItem()
        }

        //remember selection
        var selectedItemPath: String? = nil
        if selectedItem() != nil {
            selectedItemPath = selectedItem()?.path()
            setSelectedItem(nil)
        }

        //refresh item or one of its ancestors (whichever is still valid)
        var zoomedItemIsInvalid = false
        while item != nil && !item!.exists() {
            if item === zoomedItem() {
                zoomedItemIsInvalid = true
            }
            item = item?.parent()
        }

        if item == nil {
            //the folder/volume which we are showing doesn't exist anymore!
            let msg = String(format: "\"%@\" does not exist any more.", rootItem()?.displayPath() ?? "")
            let subMsg = NSLocalizedString("The folder will remain visible in Disk Inventory X, but the files cannot be accessed (e.g. shown in the Finder).", comment: "")

            let missingAlert = NSAlert()
            missingAlert.alertStyle = .informational
            missingAlert.messageText = msg
            missingAlert.informativeText = subMsg
            missingAlert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            if let window = windowControllers.first?.window {
                missingAlert.beginSheetModal(for: window, completionHandler: nil)
            }
            return
        }

        var refreshedItem: FSItem? = nil

        do {
            //we only show a progress indicator if the item to refresh has "many" childs
            assert(_progressController == nil, "progress panel wasn't destroyed after last use")
            let progressPanelLimit: UInt = (item!.fileURL()?.isLocalVolume() != true) ? 200 : 500
            if item!.deepFileCount(includingPackages: true) > progressPanelLimit {
                _progressController = LoadingPanelController()
                _progressController?.startAnimation()
            }

            let newItem = FSItem(path: item!.path())
            refreshedItem = newItem
            newItem.setDelegate(self)
            if newItem.isFolder() {
                if FSItem.parallelScanEnabled {
                    //Parallel refresh: same background-scan + main-thread pump as
                    //the initial scan. The progress panel here is optional (only
                    //shown for "many"-child items); runParallelScan tolerates a
                    //nil _progressController. Phase 2 recalc mirrors what the
                    //serial loadChildren did internally.
                    try runParallelScan(rootItem: newItem)
                    newItem.recalculateSize(true, updateParent: false)
                } else {
                    try newItem.loadChildren()
                }
            }

            _progressController = nil
        } catch FSItemError.loadingCanceled {
            //refreshing canceled by user
            _progressController?.closeNoModalEnd()
            _progressController = nil
            return
        } catch {
            _progressController?.closeNoModalEnd()
            _progressController = nil

            let failAlert = NSAlert()
            failAlert.alertStyle = .informational
            failAlert.messageText = NSLocalizedString("The folder's content could not be loaded.", comment: "")
            failAlert.informativeText = (error as NSError).localizedDescription
            failAlert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            if let window = windowControllers.first?.window {
                failAlert.beginSheetModal(for: window, completionHandler: nil)
            }
            return
        }

        //keep item valid till we are done
        if _rootItem === item {
            _rootItem = refreshedItem
            //rebuild file kind statistics
            refreshFileKindStatistics()
        } else {
            //update file kind statistics
            if !zoomedItemIsInvalid {
                willChangeValue(forKey: "kindStatistics")
            }

            removeItemFromFileKindStatistic(item!, includingChilds: true)

            let parent = item!.parent()
            parent?.replaceChild(item!, with: refreshedItem!, updateParent: true)

            addItemToFileKindStatistic(refreshedItem!, includingChilds: true)

            if !zoomedItemIsInvalid {
                didChangeValue(forKey: "kindStatistics")
            }
        }

        //if current zoomed item got invalid, zoom out as far as necessary
        if zoomedItemIsInvalid {
            var newZoomItem: FSItem? = item
            //zoom to an ancestor of "item" which is in the zoom stack
            while newZoomItem != nil && !_zoomStack.contains(where: { $0 === newZoomItem! }) {
                newZoomItem = newZoomItem?.parent()
            }

            //will post a notification about the change
            zoomOut(toItem: newZoomItem)
        } else {
            if _zoomStack.last === item {
                _zoomStack[_zoomStack.count - 1] = refreshedItem!
            }

            //notify observers of the change
            NotificationCenter.default.post(name: NSNotification.Name.FSItemsChanged, object: self)
        }

        //set selection
        if let selectedItemPath = selectedItemPath {
            //find previously selected item or one of its ancestors (whichever still exists)
            let zoomed = zoomedItem()
            let newSelection = zoomed?.findItem(byAbsolutePath: selectedItemPath, allowAncestors: true)

            if newSelection != nil && newSelection !== zoomed {
                setSelectedItem(newSelection)
            }
        }
    }

    //MARK: zoom

    @objc func zoomedItem() -> FSItem? {
        return _zoomStack.isEmpty ? rootItem() : _zoomStack.last
    }

    @objc(zoomIntoItem:)
    func zoomIntoItem(_ item: FSItem) {
        if !_zoomStack.isEmpty && item === _zoomStack.last {
            return
        }

        let oldZoomedItem = zoomedItem()

        //reset selection as the currently selected item might not be a child of the item to zoom in
        setSelectedItem(nil)

        _zoomStack.append(item)

        //the file kind statistic should only cover the currently visible part of the tree
        refreshFileKindStatistics()

        postNotification(name: NSNotification.Name.ZoomedItemChanged, oldItem: oldZoomedItem, newItem: zoomedItem())
    }

    @objc func zoomOutOneStep() {
        if !_zoomStack.isEmpty {
            let oldZoomedItem = zoomedItem()

            _zoomStack.removeLast()

            //the file kind statistic should only cover the currently visible part of the tree
            refreshFileKindStatistics()

            //there is no "other" space if a complete volume is shown
            if viewOptions().showOtherSpace && zoomedItem()?.fileURL()?.isVolume() == true {
                viewOptions().showOtherSpace = false   //don't use our set-method as we don't want notifications posted
            }

            postNotification(name: NSNotification.Name.ZoomedItemChanged, oldItem: oldZoomedItem, newItem: zoomedItem())
        }
    }

    @objc(zoomOutToItem:)
    func zoomOut(toItem item: FSItem?) {
        assert(!_zoomStack.isEmpty, "can't zoom out if zoom stack is empty")

        assert(item == nil
               || item === rootItem()
               || _zoomStack.contains(where: { $0 === item! }))

        let oldZoomedItem = zoomedItem()

        if item == nil || item === rootItem() {
            _zoomStack.removeAll()
        } else if _zoomStack.count == 1 {
            assert(item === _zoomStack.last, "zoom error")
            _zoomStack.removeAll()
        } else {
            if let itemIndex = _zoomStack.firstIndex(where: { $0 === item! }) {
                var itemsToRemove = _zoomStack.count - itemIndex - 1
                while itemsToRemove > 0 {
                    _zoomStack.removeLast()
                    itemsToRemove -= 1
                }
            }
        }

        //the file kind statistic should only cover the currently visible part of the tree
        refreshFileKindStatistics()

        //there is no "other" space if a complete volume is shown
        if viewOptions().showOtherSpace && zoomedItem()?.fileURL()?.isVolume() == true {
            viewOptions().showOtherSpace = false   //don't use our set-method as we don't want notifications posted
        }

        postNotification(name: NSNotification.Name.ZoomedItemChanged, oldItem: oldZoomedItem, newItem: zoomedItem())
    }

    @objc func zoomStack() -> NSArray {
        //bridge to NSArray to preserve the original return type
        return _zoomStack as NSArray
    }

    //MARK: selection

    @objc func selectedItem() -> FSItem? {
        return _selectedItem
    }

    @objc(setSelectedItem:)
    func setSelectedItem(_ item: FSItem?) {
        if _selectedItem === item {
            return
        }

        let oldSelectedItem = _selectedItem

        //The outline / treemap / selection-list controllers observe KVO under the
        //key "selectedItem" (DocKeySelectedItem), but the backing property is
        //_selectedItem — automatic KVO notifies for "_selectedItem", not
        //"selectedItem", so those observers would never fire. Notify the observed
        //key explicitly. (The getter selectedItem() is its KVC accessor.)
        willChangeValue(forKey: DocKeySelectedItem)
        _selectedItem = item
        didChangeValue(forKey: DocKeySelectedItem)

        //post notification
        postNotification(name: NSNotification.Name.GlobalSelectionChanged, oldItem: oldSelectedItem, newItem: _selectedItem)

        //keep info panel in sync
        if InfoPanelController.shared().panelIsVisible() {
            InfoPanelController.shared().showPanel(with: _selectedItem)
        }
    }

    //The original overrode the deprecated -fileName so the window controller
    //displays the icon of the currently zoomed item (or root item) in the title
    //bar. -fileName is unavailable in Swift; its modern replacement is -fileURL,
    //so we override that to the same effect.
    override var fileURL: URL? {
        get {
            if let path = zoomedItem()?.path() {
                return URL(fileURLWithPath: path)
            }
            return super.fileURL
        }
        set {
            super.fileURL = newValue
        }
    }

    override var displayName: String! {
        get {
            guard let zoomed = zoomedItem() else { return super.displayName }
            var displayName = zoomed.displayName()
            let sizeFormatter = FileSizeFormatter()
            let sizeStr = sizeFormatter.string(for: zoomed.size()) ?? ""
            displayName = displayName + " (\(sizeStr))"
            return displayName
        }
        set {
            super.displayName = newValue
        }
    }

    //MARK: kind statistics

    @objc func kindStatistics() -> NSDictionary {
        assert(_fileKindStatistics.count >= 0, "kind statistics aren't collected yet")
        //bridge to NSDictionary to preserve the original return type
        return _fileKindStatistics as NSDictionary
    }

    @objc(kindStatisticForItem:)
    func kindStatistic(forItem item: FSItem) -> FileKindStatistic? {
        return kindStatistic(forKind: item.kindName())
    }

    @objc(kindStatisticForKind:)
    func kindStatistic(forKind kindName: String) -> FileKindStatistic? {
        return kindStatistics().object(forKey: kindName) as? FileKindStatistic
    }

    @objc func fileTypeColors() -> FileTypeColors {
        if _kindColors == nil {
            if UserDefaults.standard.bool(forKey: ShareKindColors) {
                _kindColors = FileTypeColors.instance
            } else {
                _kindColors = FileTypeColors()
            }
        }
        return _kindColors!
    }

    //Non-throwing @objc entry point used by the controllers (zoom/view-option
    //changes); these refreshes do not surface the cancel UI. The initial scan
    //in read(fromFile:) uses the throwing variant below.
    @objc func refreshFileKindStatistics() {
        try? refreshFileKindStatisticsThrowing()
    }

    //Swift throwing variant used by the initial scan, so a user cancellation
    //during stats collection propagates as FSItemError.loadingCanceled.
    //(The ObjC original raised CollectFileKindStatisticsCanceledException here;
    //collection is purely in-memory and does not currently cancel, but the
    //throwing shape preserves the original contract.)
    private func refreshFileKindStatisticsThrowing() throws {
        willChangeValue(forKey: "kindStatistics")

        //collect sizes and file count of all file kinds
        addItemToFileKindStatistic(nil, includingChilds: true)

        //reserve the predefined colors for the kinds with the biggest size sums
        reserveColorsForLargestKinds()

        didChangeValue(forKey: "kindStatistics")
    }

    //MARK: ---------------------- FSItem delegates -----------------------------------

    @objc func fsItemEnteringFolder(_ item: FSItem) -> Bool {
        //if we don't show the progress panel, we don't need to do anything
        guard let progress = _progressController else {
            return true   //true == continue loading
        }

        if _directoryStack == nil {
            _directoryStack = []
            _directoryStack?.reserveCapacity(20)
        }

        assert(_directoryStack?.last === item.parent())
        _directoryStack?.append(item)

        //we display only folders 4 levels deep and we don't go into packages
        if (_directoryStack?.count ?? 0) <= 4 {
            var parentItem = item.parent()
            while parentItem != nil && !parentItem!.isPackage() {
                parentItem = parentItem?.parent()
            }

            if parentItem == nil {
                progress.setMessageText(item.displayPath())
            }
        }

        progress.runEventLoop()

        return !progress.cancelPressed()
    }

    @objc func fsItemExittingFolder(_ item: FSItem) -> Bool {
        //if we don't show the progress panel, we don't need to do anything
        if _progressController == nil {
            return true   //true == continue loading
        }

        assert(_directoryStack?.last === item)
        _directoryStack?.removeLast()

        return true
    }

    @objc func fsItemShouldIgnoreCreatorCode(_ item: FSItem) -> Bool {
        return ignoreCreatorCode()
    }

    @objc func fsItemShouldLookIntoPackages(_ item: FSItem) -> Bool {
        return showPackageContents()
    }

    @objc func fsItemShouldUsePhysicalFileSize(_ item: FSItem) -> Bool {
        return showPhysicalFileSize()
    }

    //MARK: -------- KVO -----------------

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey : Any]?,
                               context: UnsafeMutableRawPointer?) {
        //this global preference option is cached in an instance variable for performance reasons
        if context == &FileSystemDoc.shareKindColorsContext {
            //if "share colors" was enabled previously, reset the shared colors so we
            //get "fresh" colors the next time it is turned on again
            _kindColors?.reset()
            _kindColors = nil

            reserveColorsForLargestKinds()
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    //MARK: ---------------------- private helpers -----------------------------------

    private func viewOptions() -> NSMutableDictionary {
        return _viewOptions
    }

    private func postViewOptionChangedNotification(forOption optionName: String) {
        let userInfo = [ChangedViewOption: optionName]
        NotificationCenter.default.post(name: NSNotification.Name.ViewOptionChanged,
                                        object: self,
                                        userInfo: userInfo)
    }

    private func postNotification(name: NSNotification.Name, oldItem old: FSItem?, newItem new: FSItem?) {
        var info: [String: Any] = [:]
        if let old = old { info[OldItem] = old }
        if let new = new { info[NewItem] = new }

        NotificationCenter.default.post(name: name, object: self, userInfo: info)
    }

    private func recalculateTotalSize() {
        rootItem()?.recalculateSize(showPhysicalFileSize(), updateParent: false)
    }

    private func addItemToFileKindStatistic(_ itemParam: FSItem?, includingChilds: Bool) {
        var item = itemParam

        //if we are called with nil as item, we rebuild the statistic
        if item == nil {
            _fileKindStatistics = [:]
            item = zoomedItem()
        }

        guard let item = item else { return }

        if !itemIsNode(item) {
            //item is a file (or regarded as such if item is a package and "show package contents" is off),
            //so add its information to the appropriate statistic object
            let kind = item.kindName()
            if !kind.isEmpty {
                if let kindStatistic = kindStatistic(forItem: item) {
                    kindStatistic.add(item)
                } else {
                    //we don't have a statistic object for the item's kind yet, so create one
                    let kindStatistic = FileKindStatistic(item: item)
                    _fileKindStatistics[kind] = kindStatistic
                }
            }
        } else if includingChilds {
            //if the item is a folder, recurse through its childs
            var i = item.childCount()
            while i > 0 {
                i -= 1
                if let child = item.child(at: i) {
                    addItemToFileKindStatistic(child, includingChilds: true)
                }
            }
        }
    }

    private func removeItemFromFileKindStatistic(_ item: FSItem, includingChilds: Bool) {
        if !itemIsNode(item) {
            //item is a file: remove its information from the appropriate statistic object
            if let kindStatistic = kindStatistic(forItem: item) {
                kindStatistic.remove(item)
            }
        } else if includingChilds {
            //if the item is a folder, recurse through its childs
            var i = item.childCount()
            while i > 0 {
                i -= 1
                if let child = item.child(at: i) {
                    removeItemFromFileKindStatistic(child, includingChilds: true)
                }
            }
        }
    }

    private func recalculateFileKindStatisticSizes() {
        willChangeValue(forKey: "kindStatistics")

        for statistic in _fileKindStatistics.values {
            statistic.recalculateSize()
        }

        didChangeValue(forKey: "kindStatistics")
    }

    private func reserveColorsForLargestKinds() {
        //order Statistics descendingly by size, mirroring the former
        //NSMutableArray.sortUsingSelector(compareSizeDescendingly:)
        let kinds = _fileKindStatistics.values.sorted {
            $0.compareSizeDescendingly($1) == .orderedAscending
        }

        for kindStat in kinds {
            _ = fileTypeColors().color(forKind: kindStat.kindName)
        }
    }

    private func checkForProtectedFolders(_ folder: String) {
        let fileMgr = FileManager.default
        let protectedFolders = fileMgr.privacyProtectedFolders(in: NSURL(fileURLWithPath: folder) as URL)
        if protectedFolders.count > 0 {
            let defaults = UserDefaults.standard
            if !defaults.boolForVersionDependantKey(DontShowPrivacyWarningMessage) {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = NSLocalizedString("Some folders which will be scanned contain private files. The access is protected by the macOS privacy protection.\n\nUpon first access macOS will ask whether you allow Disk Inventory X access to these folders and files.\n\nDisk Inventory X does not read any data - just information like file sizes and types are collected.", comment: "")
                alert.informativeText = NSLocalizedString("You can change the access settings in the System Preferences (Security/Privacy).", comment: "")

                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = NSLocalizedString("Do not show this information again.", comment: "")

                alert.runModal()

                if alert.suppressionButton?.state == .on {
                    // Suppress this alert for the current version
                    defaults.setBool(true, forVersionDependantKey: DontShowPrivacyWarningMessage)
                }

                // let the alert disappear before the consent dialogs pop up
                RunLoop.current.run(until: Date())
            }

            fileMgr.triggerConsentDialog(forPrivacyProtectedFolders: protectedFolders)
        }
    }
}
