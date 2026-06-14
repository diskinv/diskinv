//
//  FSItem.swift
//  Disk Inventory X
//
//  Swift port of the central model class FSItem: the recursive folder
//  scanner and tree node. Ported faithfully from the original
//  Objective-C FSItem.h/.m. ARC throughout.
//
//  Non-class support symbols (FSItemType enum, g_fileCount/g_folderCount
//  globals, the exception name constants, and the NSString
//  compareAsFilesystemName: category) live in FSItemSupport.h/.m and are
//  visible here via the bridging header.
//
//  GPL v3
//

import Cocoa
import CoreServices
import os   //os_unfair_lock

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

//MARK: - delegate informal protocol -> @objc protocol

@objc protocol FSItemDelegate: NSObjectProtocol {
    @objc optional func fsItemEnteringFolder(_ item: FSItem) -> Bool   //delegate may return NO to stop loading in "loadChildren"
    @objc optional func fsItemExittingFolder(_ item: FSItem) -> Bool
    @objc optional func fsItemShouldIgnoreCreatorCode(_ item: FSItem) -> Bool   //default is NO (if not implemented)
    @objc optional func fsItemShouldLookIntoPackages(_ item: FSItem) -> Bool    //default is NO (if not implemented)
    @objc optional func fsItemShouldUsePhysicalFileSize(_ item: FSItem) -> Bool
}

//global cache for kind names.
//
//During the parallel scan multiple worker threads call
//setKindStringIncludingChildren concurrently, all reading/writing this cache.
//Its contents are a pure function of the UTI identifier string, so a
//serialized get-or-compute is correct. We guard every access with
//g_kindNameDictionaryLock (an os_unfair_lock wrapped in a tiny helper). The
//serial path goes through the same locked accessor, so behavior is identical.
private var g_kindNameDictionary = NSMutableDictionary()
private var g_kindNameDictionaryLock = UnfairLock()

//Minimal os_unfair_lock wrapper. os_unfair_lock is available since 10.12, well
//under the 10.13 deployment target, and is cheaper than NSLock for the very
//short critical sections used here. The lock value is held in a heap box so the
//struct can be a `let` global without tripping Swift's exclusive-access checks
//on the mutating lock/unlock calls.
final class UnfairLock {
    private let _lock: os_unfair_lock_t = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    deinit {
        _lock.deinitialize(count: 1)
        _lock.deallocate()
    }

    func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(_lock)
        defer { os_unfair_lock_unlock(_lock) }
        return body()
    }
}

//MARK: - scan errors (replaces the former ObjC NSException-based cancellation)

//Errors thrown by the recursive scanner. Both FSItem and its sole caller
//(FileSystemDoc) are now Swift, so idiomatic Swift errors replace the
//former FSItemLoadingCanceledException / FSItemLoadingFailedException
//NSExceptions.
enum FSItemError: Error {
    case loadingCanceled   //delegate canceled the loading
    case loadingFailed     //error while enumerating files/folders
}

//MARK: - thread-safe scan progress / cancel channel

//Shared between the background scan (coordinator + workers) and the main-thread
//progress pump. All access is guarded by an internal lock so reads/writes never
//tear. Workers only ever WRITE foldersScanned/currentPath and READ cancelled;
//the main thread READs progress, WRITES cancelled, and READs/WRITES finished.
final class ScanProgress {
    private let lock = UnfairLock()
    private var _foldersScanned: Int = 0
    private var _currentPath: String = ""
    private var _cancelled: Bool = false
    private var _finished: Bool = false

    var foldersScanned: Int {
        get { lock.withLock { _foldersScanned } }
        set { lock.withLock { _foldersScanned = newValue } }
    }

    var currentPath: String {
        get { lock.withLock { _currentPath } }
        set { lock.withLock { _currentPath = newValue } }
    }

    var cancelled: Bool {
        get { lock.withLock { _cancelled } }
        set { lock.withLock { _cancelled = newValue } }
    }

    var finished: Bool {
        get { lock.withLock { _finished } }
        set { lock.withLock { _finished = newValue } }
    }

    //Bump the folder counter and record the current path in one locked section
    //(workers call this at each directory boundary).
    func noteEnteredFolder(path: String) {
        lock.withLock {
            _foldersScanned += 1
            _currentPath = path
        }
    }
}

@objc(FSItem) final class FSItem: NSObject {

    private var _fileURL: NSURL?
    //only valid for non-root items (non-owning back-reference); the original
    //used __unsafe_unretained because parents own children via _childs.
    private unowned(unsafe) var _parent: FSItem?
    private var _icons: NSMutableDictionary?   //holds icons in various sizes (see iconWithSize:)
    private var _type: FSItemType = FileFolderItem
    private var _size: NSNumber?
    private var _sizeValue: UInt64 = 0
    private var _kindName: String?
    //Private backing storage: native Swift array of child items. The public
    //accessors (childEnumerator/childAtIndex:/childCount) keep their original
    //return types and bridge to NS* at the boundary.
    private var _childs: [FSItem]?
    //non-owning, like the original __unsafe_unretained id
    private unowned(unsafe) var _delegate: AnyObject?

    //MARK: initializers

    @objc(initWithPath:)
    init(path: String) {
        super.init()
        let url = NSURL(fileURLWithPath: path)
        commonInit(url: url)
    }

    @objc(initWithURL:)
    init(url: NSURL) {
        super.init()
        commonInit(url: url)
    }

    private func commonInit(url: NSURL) {
        _type = FileFolderItem
        _fileURL = url
        if url.isDirectory() {
            _childs = []
        }
        _parent = nil   //we are the root item
    }

    @objc(initAsOtherSpaceItemForParent:)
    init(asOtherSpaceItemForParent parent: FSItem) {
        super.init()
        _type = OtherSpaceItem
        _parent = parent   //weak reference
        recalculateSize(false, updateParent: false)
    }

    @objc(initAsFreeSpaceItemForParent:)
    init(asFreeSpaceItemForParent parent: FSItem) {
        super.init()
        _type = FreeSpaceItem
        _parent = parent
        recalculateSize(false, updateParent: false)
    }

    // private designated initializer used by the scanner
    @objc(initWithURL:parent:setKindString:usePhysicalSize:)
    init(url: NSURL, parent: FSItem?, setKindString: Bool, usePhysicalSize: Bool) {
        super.init()
        _type = FileFolderItem
        _parent = parent   //no retain

        if let parent = parent {
            parent._childs?.append(self)
        }

        _fileURL = url

        let isFolder = url.isDirectory()

        if !isFolder {
            if usePhysicalSize {
                setSizeValue(url.physicalSize().uint64Value)
            } else {
                setSizeValue(url.logicalSize().uint64Value)
            }
        } else {
            _childs = []
        }

        if setKindString {
            setKindStringIncludingChildren(false)
        }

        if isFolder {
            g_folderCount += 1
        } else {
            g_fileCount += 1
        }
    }

    //Parallel-scan node initializer. Identical to the designated scanner init
    //above EXCEPT it does not mutate the g_fileCount/g_folderCount globals;
    //instead it tallies into the worker-local `counts` (merged after join). Used
    //only from a single worker thread for nodes within that worker's disjoint
    //subtree, so the parent._childs append is the sole writer of that array.
    init(url: NSURL, parent: FSItem?, setKindString: Bool, usePhysicalSize: Bool,
         counts: inout ScanCounts) {
        super.init()
        _type = FileFolderItem
        _parent = parent   //no retain

        if let parent = parent {
            parent._childs?.append(self)
        }

        _fileURL = url

        let isFolder = url.isDirectory()

        if !isFolder {
            if usePhysicalSize {
                setSizeValue(url.physicalSize().uint64Value)
            } else {
                setSizeValue(url.logicalSize().uint64Value)
            }
        } else {
            _childs = []
        }

        if setKindString {
            setKindStringIncludingChildren(false)
        }

        if isFolder {
            counts.folders += 1
        } else {
            counts.files += 1
        }
    }

    deinit {
        //nil out children's non-owning back-reference before ARC releases _childs
        if let childs = _childs {
            for child in childs {
                child.onParentDealloc()
            }
        }
    }

    //MARK: delegate

    @objc(delegate)
    func delegate() -> AnyObject? {
        return root()._delegate
    }

    @objc(setDelegate:)
    func setDelegate(_ delegate: AnyObject?) {
        _delegate = delegate   //no retain
    }

    //convenience: typed access to the delegate's optional methods
    private var delegateAsFSItemDelegate: FSItemDelegate? {
        return delegate() as? FSItemDelegate
    }

    //MARK: type / basics

    @objc(type)
    func type() -> FSItemType {
        return _type
    }

    @objc(isSpecialItem)
    func isSpecialItem() -> Bool {
        return _type != FileFolderItem
    }

    @objc(fileURL)
    func fileURL() -> NSURL? {
        if !isSpecialItem() {
            return _fileURL
        } else {
            return root().fileURL()
        }
    }

    @objc(setFileURL:)
    func setFileURL(_ url: NSURL?) {
        assert(!isSpecialItem(), "free and other space items don't have a NTFileDesc object")
        _fileURL = url
    }

    override func isEqual(_ object: Any?) -> Bool {
        //We don't check real equality here. This method is only intended to support NSSet.
        return (object as AnyObject?) === self
    }

    override var description: String {
        switch _type {
        case FileFolderItem:
            return fileURL()?.description ?? ""
        case FreeSpaceItem:
            return "FreeSpaceItem"
        case OtherSpaceItem:
            return "OtherSpaceItem"
        default:
            assert(false, "unknown item type")
            return ""
        }
    }

    //MARK: tree navigation

    @objc(parent)
    func parent() -> FSItem? {
        return _parent
    }

    @objc(root)
    func root() -> FSItem {
        if isRoot() {
            return self
        } else {
            return parent()!.root()
        }
    }

    @objc(isRoot)
    func isRoot() -> Bool {
        return _parent == nil
    }

    @objc(setParent:)
    func setParent(_ parent: FSItem?) {
        _parent = parent   //weak reference (parent owns us)
        _delegate = nil    //we use our parent's delegate
    }

    @objc(onParentDealloc)
    func onParentDealloc() {
        _parent = nil
    }

    //MARK: file kind predicates

    @objc(isFolder)
    func isFolder() -> Bool {
        //returns NO for an alias pointing to a directory
        if !isSpecialItem() {
            return _fileURL?.cachedIsDirectory() ?? false
        } else {
            return false
        }
    }

    @objc(isPackage)
    func isPackage() -> Bool {
        if !isSpecialItem() {
            return _fileURL?.cachedIsPackage() ?? false
        } else {
            return false
        }
    }

    @objc(isAlias)
    func isAlias() -> Bool {
        if !isSpecialItem() {
            return _fileURL?.cachedIsAliasOrSymbolicLink() ?? false
        } else {
            return false
        }
    }

    @objc(exists)
    func exists() -> Bool {
        return fileURL()?.stillExists() ?? false
    }

    @objc(iconWithSize:)
    func icon(withSize iconSize: UInt32) -> NSImage? {
        //items for free space and other space don't have an icon
        if isSpecialItem() {
            return nil
        }

        if _icons == nil {
            _icons = NSMutableDictionary()
        }

        let key = NSNumber(value: iconSize)
        var icon = _icons?.object(forKey: key) as AnyObject?
        if icon == nil {
            //NSWorkspace.icon(forFile:) hands back an NSImage backed by a SHARED,
            //lazily-evaluated icon-rep provider (NSImageISIconRepProvider). That
            //provider can be released out from under us elsewhere, leaving our
            //cached image with a dangling provider that crashes on the next draw
            //(use-after-free in the table/outline cell). Rasterize into a small,
            //self-contained bitmap so the cached icon owns its pixels outright and
            //holds no reference to NSWorkspace's shared provider.
            let size = NSMakeSize(CGFloat(iconSize), CGFloat(iconSize))
            let source = NSWorkspace.shared.icon(forFile: fileURL()?.path ?? "")
            let baked = NSImage(size: size)
            baked.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: NSRect(origin: .zero, size: size),
                        from: .zero, operation: .sourceOver, fraction: 1.0)
            baked.unlockFocus()
            icon = baked
            _icons?.setObject(baked, forKey: key)
        }

        if icon is NSNull {
            return nil
        }
        return icon as? NSImage
    }

    //MARK: ----------------- child handlers -----------------------

    @objc(childEnumerator)
    func childEnumerator() -> NSEnumerator? {
        if !isSpecialItem() {
            //bridge to NSArray to preserve the original NSEnumerator return type
            return (_childs as NSArray?)?.objectEnumerator()
        } else {
            return nil
        }
    }

    @objc(childAtIndex:)
    func child(at index: UInt) -> FSItem? {
        if !isSpecialItem() {
            return _childs?[Int(index)]
        } else {
            return nil
        }
    }

    @objc(childCount)
    func childCount() -> UInt {
        if !isSpecialItem() {
            return UInt(_childs?.count ?? 0)
        } else {
            return 0
        }
    }

    @objc(removeChild:updateParent:)
    func removeChild(_ child: FSItem, updateParent: Bool) {
        assert(!isSpecialItem(), "removeChild is illegal call for special item")

        guard var childs = _childs else { return }
        //identity match, mirroring NSMutableArray.indexOfObjectIdenticalTo:
        if let index = childs.firstIndex(where: { $0 === child }) {
            let myOldSize = sizeValue()
            let myNewSize = myOldSize - child.sizeValue()

            setSizeValue(myNewSize)

            childs.remove(at: index)
            _childs = childs

            if updateParent && !isRoot() {
                parent()!.childChanged(self, oldSize: myOldSize, newSize: myNewSize)
            }
        }
    }

    @objc(insertChild:updateParent:)
    func insertChild(_ newChild: FSItem, updateParent: Bool) {
        let myOldSize = sizeValue()

        newChild.setParent(self)

        //insert child sorted by size (descending), mirroring the former
        //-indexOfObject:inSortedRange:options:NSBinarySearchingInsertionIndex
        //usingComparator: with compareSizeDescendingly.
        guard var childs = _childs else { return }
        let insertIndex = FSItem.sortedInsertionIndex(of: newChild, in: childs) {
            $0.compareSizeDescendingly($1)
        }
        childs.insert(newChild, at: insertIndex)
        _childs = childs

        setSizeValue(sizeValue() + newChild.sizeValue())

        if updateParent && !isRoot() {
            parent()!.childChanged(self, oldSize: myOldSize, newSize: sizeValue())
        }
    }

    @objc(replaceChild:withItem:updateParent:)
    func replaceChild(_ oldChild: FSItem, with newChild: FSItem, updateParent: Bool) {
        if oldChild !== newChild {
            let myOldSize = sizeValue()

            removeChild(oldChild, updateParent: false)
            insertChild(newChild, updateParent: false)

            if updateParent && !isRoot() {
                parent()!.childChanged(self, oldSize: myOldSize, newSize: sizeValue())
            }
        }
    }

    //if this is a folder, load all containing files
    //Called only by FileSystemDoc (now Swift), so no @objc exposure is needed.
    //
    //This is the SERIAL entry point, kept for the (rare) callers that drive the
    //scan inline on the calling thread and rely on the delegate enter/exit
    //callbacks for progress (it pumps the runloop via fsItemEnteringFolder:).
    //The parallel scan is orchestrated separately by the document via
    //loadChildrenParallel(params:progress:) so the main thread stays free to
    //pump the progress panel; see FileSystemDoc.readFromFolder.
    func loadChildren() throws {
        var usePhysicalSize = false

        if let d = delegateAsFSItemDelegate, let result = d.fsItemShouldUsePhysicalFileSize?(self) {
            usePhysicalSize = result
        }

        //use new optimized version of loadChilds
        try loadChildrenSerial(true, usePhysicalSize: usePhysicalSize)
    }

    //MARK: ----------------- parallel scan: toggle / params / progress ----------

    //Runtime A/B toggle. Default TRUE (parallel). Set the environment variable
    //DIX_PARALLEL_SCAN=0 to force the original serial path in the same binary,
    //so the two can be diffed for byte-identical results.
    static let parallelScanEnabled: Bool = {
        if ProcessInfo.processInfo.environment["DIX_PARALLEL_SCAN"] == "0" {
            return false
        }
        return true
    }()

    //Immutable snapshot of the behavior flags, taken ONCE on the main thread
    //before any worker is dispatched. Workers read this struct instead of
    //calling the (main-thread-only) FSItemDelegate. Value type => freely shared
    //by copy across threads with no synchronization.
    struct ScanParams {
        let setKindStrings: Bool
        let usePhysicalSize: Bool
        let lookIntoPackages: Bool   //snapshot of fsItemShouldLookIntoPackages
    }

    //Build the ScanParams by querying the delegate. MUST be called on the main
    //thread (the delegate touches document/UI state).
    func makeScanParams(setKindStrings: Bool) -> ScanParams {
        let d = delegateAsFSItemDelegate
        var usePhysicalSize = false
        if let d = d, let r = d.fsItemShouldUsePhysicalFileSize?(self) { usePhysicalSize = r }
        var lookInto = false
        if let d = d, let r = d.fsItemShouldLookIntoPackages?(self) { lookInto = r }
        return ScanParams(setKindStrings: setKindStrings,
                          usePhysicalSize: usePhysicalSize,
                          lookIntoPackages: lookInto)
    }

    //Per-worker scan tallies. Accumulated locally inside a worker's serial
    //descent (no shared global mutation), then merged after join and assigned to
    //the g_fileCount/g_folderCount globals on the coordinator. (Debug-only.)
    struct ScanCounts {
        var files: UInt32 = 0
        var folders: UInt32 = 0
        static func + (a: ScanCounts, b: ScanCounts) -> ScanCounts {
            ScanCounts(files: a.files + b.files, folders: a.folders + b.folders)
        }
    }

    //MARK: ----------------- sizes -----------------------

    @objc(size)
    func size() -> NSNumber {
        if _size == nil {
            _size = NSNumber(value: _sizeValue)
        }
        return _size!
    }

    @objc(sizeValue)
    func sizeValue() -> UInt64 {
        return _sizeValue
    }

    @objc(setSize:)
    func setSize(_ newSize: NSNumber) {
        assert(true)
        if _size !== newSize {
            _size = newSize
            _sizeValue = newSize.uint64Value
        }
    }

    @objc(setSizeValue:)
    func setSizeValue(_ newSize: UInt64) {
        _sizeValue = newSize
        _size = nil
    }

    @objc(recalculateSize:updateParent:)
    func recalculateSize(_ usePhysicalSize: Bool, updateParent: Bool) {
        //just recalculates size (no file system access)
        let oldSize = sizeValue()
        var size: UInt64 = 0

        switch _type {
        case FileFolderItem:
            if isFolder() {
                if var childs = _childs {
                    var i = childs.count
                    while i > 0 {
                        i -= 1
                        let child = childs[i]
                        child.recalculateSize(usePhysicalSize, updateParent: false)
                        size += child.sizeValue()
                    }
                    //sort descending by size, mirroring the former
                    //NSMutableArray.sortUsingSelector(compareSizeDescendingly:)
                    childs.sort { $0.compareSizeDescendingly($1) == .orderedAscending }
                    _childs = childs
                }
            } else {
                //File
                if usePhysicalSize {
                    size = _fileURL?.cachedPhysicalSize().uint64Value ?? 0
                } else {
                    size = _fileURL?.cachedLogicalSize().uint64Value ?? 0
                }
            }

        case FreeSpaceItem:
            let freeSpace = fileURL()?.getCachedNumberValue(URLResourceKey.volumeAvailableCapacityKey.rawValue)
            size = freeSpace?.uint64Value ?? 0

        case OtherSpaceItem:
            let totalSpace = fileURL()?.getCachedNumberValue(URLResourceKey.volumeTotalCapacityKey.rawValue)
            let freeSpace = fileURL()?.getCachedNumberValue(URLResourceKey.volumeAvailableCapacityKey.rawValue)

            let totalSpaceVal: UInt64 = totalSpace?.uint64Value ?? 0
            let freeSpaceVal: UInt64 = freeSpace?.uint64Value ?? 0

            //the root item must have finished calculating its size, otherwise this doesn't work
            size = totalSpaceVal &- root().sizeValue() &- freeSpaceVal

        default:
            break
        }

        setSizeValue(size)

        if updateParent && !isRoot() {
            parent()!.childChanged(self, oldSize: oldSize, newSize: size)
        }
    }

    //MARK: kind name

    //get display string for kind ("Application", "Simple Text Document", ...)
    @objc(kindName)
    func kindName() -> String {
        if !isSpecialItem() {
            if _kindName == nil {
                setKindString()
            }
            return _kindName ?? ""
        } else {
            return ""
        }
    }

    @objc(setKindString)
    func setKindString() {
        //will ask delegate whether to ignore creator codes
        var ignoreCreatorCode = false
        if let d = delegateAsFSItemDelegate, let result = d.fsItemShouldIgnoreCreatorCode?(self) {
            ignoreCreatorCode = result
        }
        _ = ignoreCreatorCode   //preserved for parity with original (unused beyond the query)

        setKindStringIncludingChildren(false)
    }

    //determines the kind of the file/folder as shown in Finder's Get Info.
    //(The type/creator-based code in the original is commented out; only the
    //live UTI-based code is ported.)
    @objc(setKindStringIncludingChildren:)
    func setKindStringIncludingChildren(_ includingChildren: Bool) {
        let uti = _fileURL?.cachedUTI()

        if let uti = uti {
            //Lock-protected get-or-compute. Safe to call from parallel scan
            //workers: the cache contents depend only on `uti`, so a serialized
            //lookup yields the same kind name regardless of thread order.
            _kindName = g_kindNameDictionaryLock.withLock {
                if let cached = g_kindNameDictionary.object(forKey: uti) as? String {
                    return cached
                }
                let computed = FSItem.localizedDescription(forUTI: uti)
                //remember kind name for similar files
                if let kn = computed {
                    g_kindNameDictionary.setObject(kn, forKey: uti as NSString)
                }
                return computed
            }
        } else {
            _kindName = nil
        }

        if _kindName == nil {
            _kindName = _fileURL?.getCachedStringValue(URLResourceKey.localizedTypeDescriptionKey.rawValue)
        }

        //let our childs do the same
        if includingChildren && isFolder() {
            var i = childCount()
            while i > 0 {
                i -= 1
                child(at: i)?.setKindStringIncludingChildren(true)
            }
        }
    }

    //MARK: ----------------- UTI helpers -----------------------
    //
    //These wrap the modern UniformTypeIdentifiers framework (macOS 11+) with a
    //fallback to the deprecated CoreServices UTType* C APIs for the project's
    //10.13 deployment target. The cached UTI is a plain identifier string (as
    //returned by NSURL.cachedUTI / typeIdentifierKey), so these helpers operate
    //on identifier strings to preserve the exact pre-existing behavior.

    //localized "kind" description for a UTI identifier (e.g. "Rich Text Document")
    private static func localizedDescription(forUTI uti: String) -> String? {
        if #available(macOS 11.0, *) {
            return UTType(uti)?.localizedDescription
        } else {
            return UTTypeCopyDescription(uti as CFString)?.takeRetainedValue() as String?
        }
    }

    //does the file's UTI identifier conform to the image type?
    private static func utiConformsToImage(_ uti: String) -> Bool {
        if #available(macOS 11.0, *) {
            return UTType(uti)?.conforms(to: .image) ?? false
        } else {
            return UTTypeConformsTo(uti as CFString, kUTTypeImage)
        }
    }

    //identifier strings for the small set of well-known types this class
    //compares against by identity. Using the framework constant's identifier
    //yields the exact same string the legacy kUTType* constants produced
    //(e.g. "public.rtf"), so behavior is unchanged.
    private enum UTIIdentifier {
        static let rtf: String = {
            if #available(macOS 11.0, *) { return UTType.rtf.identifier }
            return kUTTypeRTF as String
        }()
        static let rtfd: String = {
            if #available(macOS 11.0, *) { return UTType.rtfd.identifier }
            return kUTTypeRTFD as String
        }()
        static let flatRTFD: String = {
            if #available(macOS 11.0, *) { return UTType.flatRTFD.identifier }
            return kUTTypeFlatRTFD as String
        }()
        static let tiff: String = {
            if #available(macOS 11.0, *) { return UTType.tiff.identifier }
            return kUTTypeTIFF as String
        }()
        static let html: String = {
            if #available(macOS 11.0, *) { return UTType.html.identifier }
            return kUTTypeHTML as String
        }()
        static let pdf: String = {
            if #available(macOS 11.0, *) { return UTType.pdf.identifier }
            return kUTTypePDF as String
        }()
    }

    //MARK: names / paths

    @objc(name)
    func name() -> String {
        switch _type {
        case FileFolderItem:
            return fileURL()?.cachedName() ?? ""
        case FreeSpaceItem:
            return "FreeSpaceItem"
        case OtherSpaceItem:
            return "OtherSpaceItem"
        default:
            assert(false, "unknown item type")
            return ""
        }
    }

    @objc(path)
    func path() -> String {
        if !isSpecialItem() {
            if isRoot() {
                return fileURL()?.cachedPath() ?? ""
            } else {
                //parent path + "/" + name
                return (parent()!.path() as NSString).appendingPathComponent(name())
            }
        } else {
            return name()
        }
    }

    @objc(folderName)
    func folderName() -> String {
        if !isSpecialItem() {
            if let parent = parent() {
                return parent.path()
            } else {
                return (path() as NSString).deletingLastPathComponent
            }
        } else {
            return ""
        }
    }

    //display string for name (with or without extension; localized file names)
    @objc(displayName)
    func displayName() -> String {
        switch _type {
        case FileFolderItem:
            var name = fileURL()?.cachedDisplayName()
            if name == nil {
                name = fileURL()?.cachedName()
            }
            if name == nil {
                name = ""
            }
            return name!
        case FreeSpaceItem:
            return NSLocalizedString("free space on drive", comment: "")
        case OtherSpaceItem:
            return NSLocalizedString("space occupied by other files and folders", comment: "")
        default:
            assert(false, "unknown item type")
            return ""
        }
    }

    @objc(displayFolderName)
    func displayFolderName() -> String {
        //folder name relative to root item, not "/"
        if !isSpecialItem() {
            if let parent = parent() {
                return (parent.displayFolderName() as NSString).appendingPathComponent(parent.displayName())
            } else {
                return ""
            }
        } else {
            return ""
        }
    }

    @objc(displayPath)
    func displayPath() -> String {
        //path relative to root item, not "/"
        if !isSpecialItem() {
            return (displayFolderName() as NSString).appendingPathComponent(displayName())
        } else {
            return displayName()
        }
    }

    //MARK: ----------------- comparison helpers -----------------------

    @objc(compareSize:)
    func compareSize(_ other: FSItem) -> ComparisonResult {
        //if just one of the 2 FSItems (self xor other) is a special item, then the special
        //item is considered to be smaller (so the special items are at the end of the child array)
        if isSpecialItem() != other.isSpecialItem() {
            return .orderedDescending
        }

        let mySize = sizeValue()
        let otherSize = other.sizeValue()

        if mySize > otherSize {
            return .orderedDescending
        }
        if mySize < otherSize {
            return .orderedAscending
        }

        //if both FSItems have the same size, order by their names
        return (name() as NSString).compare(asFilesystemName:other.name())
    }

    @objc(compareDisplayName:)
    func compareDisplayName(_ other: FSItem) -> ComparisonResult {
        return (displayName() as NSString).compare(asFilesystemName:other.displayName())
    }

    //compare the size of 2 FSItems (descending)
    @objc(compareSizeDescendingly:)
    func compareSizeDescendingly(_ other: FSItem) -> ComparisonResult {
        //flip result of compareSize:
        switch compareSize(other) {
        case .orderedDescending:
            return .orderedAscending
        case .orderedAscending:
            return .orderedDescending
        default:
            return .orderedSame
        }
    }

    //Binary-search insertion index into a comparator-sorted array, replicating
    //-[NSArray indexOfObject:inSortedRange:options:NSBinarySearchingInsertionIndex
    //usingComparator:]. Returns the index at which `element` can be inserted to
    //keep the array ordered. For runs of comparator-equal elements this returns
    //the upper bound of that run (a valid insertion point), matching the
    //sorted-order result the original produced.
    private static func sortedInsertionIndex(of element: FSItem,
                                             in array: [FSItem],
                                             comparator: (FSItem, FSItem) -> ComparisonResult) -> Int {
        var lo = 0
        var hi = array.count
        while lo < hi {
            let mid = (lo + hi) / 2
            //element < array[mid]  => insert in lower half
            if comparator(element, array[mid]) == .orderedAscending {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return lo
    }

    //MARK: ----------------- child change propagation -----------------------

    @objc(childChanged:oldSize:newSize:)
    func childChanged(_ child: FSItem, oldSize: UInt64, newSize: UInt64) {
        if oldSize == newSize {
            return
        }

        let myOldSize = sizeValue()
        let myNewSize = myOldSize &- oldSize &+ newSize

        //keep childs array sorted
        removeChild(child, updateParent: false)
        insertChild(child, updateParent: false)

        setSizeValue(myNewSize)

        if !isRoot() {
            parent()!.childChanged(self, oldSize: myOldSize, newSize: myNewSize)
        }
    }

    //MARK: ----------------- the scanner (serial) -----------------------
    //
    //PRESERVED UNCHANGED as the `parallelScanEnabled == false` path. This is the
    //original flat-enumerator deep walk; it drives progress/cancel through the
    //fsItemEnteringFolder:/fsItemExittingFolder: delegate callbacks (which pump
    //the runloop) and increments g_fileCount/g_folderCount via the per-item
    //initializer. Do not change its behavior — it is the byte-identical baseline.
    func loadChildrenSerial(_ setKindStringsParam: Bool, usePhysicalSize: Bool) throws {
        if !isFolder() {
            return
        }

        var setKindStrings = setKindStringsParam
        let delegate = delegateAsFSItemDelegate

        //should we cancel the loading?
        if let d = delegate, d.fsItemEnteringFolder?(self) == false {
            throw FSItemError.loadingCanceled
        }

        _childs = []

        //should the kind strings of our childs be set initially? (optimization)
        if setKindStrings && !isRoot() {
            var lookInto = false
            if let d = delegate, let result = d.fsItemShouldLookIntoPackages?(self) {
                lookInto = result
            }
            if !lookInto {
                setKindStrings = !isPackage()
            }
        }

        let urlProperties: [URLResourceKey] = [
            //.localizedNameKey,
            .nameKey,
            .isVolumeKey,
            .isPackageKey,
            .isDirectoryKey,
            //.isSymbolicLinkKey,
            .typeIdentifierKey,
            //.localizedTypeDescriptionKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey
        ]

        // stack of directories (path to directory currently being scanned)
        let itemStack = NSMutableArray()
        itemStack.add(self)

        let selfURL = fileURL()
        let dirEnum = FileManager.default.enumerator(at: selfURL! as URL,
                                                     includingPropertiesForKeys: urlProperties,
                                                     options: [],
                                                     errorHandler: { (url, error) -> Bool in
                                                         // stop if there is a problem with the directory itself
                                                         if let selfURL = selfURL, (url as NSURL).isEqual(to: selfURL as URL) {
                                                             return false
                                                         } else {
                                                             return true
                                                         }
                                                     })

        var lastEnumLevel = 1
        var lastItemWasDir = false
        var lastDirItem: FSItem? = nil

        if let dirEnum = dirEnum {
            for case let current as URL in dirEnum {
                //autoreleasepool is `rethrows`, so a throwing body propagates out
                try autoreleasepool {
                    let currentUrl = current as NSURL

                    // cache all needed properties (NSURL purges all values upon next pass through the run loop)
                    currentUrl.cacheResources(in: urlProperties)

                    if dirEnum.level > lastEnumLevel {
                        // we have entered a sub directory
                        itemStack.add(lastDirItem!)

                        //should we cancel the loading?
                        if let d = delegate, d.fsItemEnteringFolder?(lastDirItem!) == false {
                            throw FSItemError.loadingCanceled
                        }
                    } else if dirEnum.level < lastEnumLevel {
                        // level can be one or more steps higher
                        let levelsWalkedUp = lastEnumLevel - dirEnum.level

                        // walk n levels up
                        for _ in 0..<levelsWalkedUp {
                            //should we cancel the loading?
                            if let d = delegate, let last = itemStack.lastObject as? FSItem, d.fsItemExittingFolder?(last) == false {
                                throw FSItemError.loadingCanceled
                            }
                            itemStack.removeLastObject()
                        }
                    }

                    let currentItem = FSItem(url: currentUrl,
                                             parent: itemStack.lastObject as? FSItem,
                                             setKindString: setKindStrings,
                                             usePhysicalSize: usePhysicalSize)

                    if currentUrl.isFirmlink() {
                        // firmlinks are not followed by NSDirectoryEnumerator, but Apple may
                        // change that, so we tell the enumerator to not enter the directory
                        dirEnum.skipDescendants()
                        try currentItem.loadChildrenSerial(setKindStrings, usePhysicalSize: usePhysicalSize)
                    } else if currentUrl.isVolume() {
                        // on 10.15 Beta 7 the mount point /System/Volume/data is followed,
                        // although this should not be the case according to the docs
                        dirEnum.skipDescendants()
                    }

                    lastItemWasDir = currentUrl.isDirectory()
                    lastDirItem = lastItemWasDir ? currentItem : nil
                    lastEnumLevel = dirEnum.level
                }
            }
        }

        // signal exiting of remaining folders
        for case let stackItem as FSItem in itemStack.reverseObjectEnumerator() {
            //should we cancel the loading?
            if let d = delegate, d.fsItemExittingFolder?(stackItem) == false {
                throw FSItemError.loadingCanceled
            }
        }

        recalculateSize(true, updateParent: false)
    }

    //MARK: ----------------- the scanner (parallel) -----------------------
    //
    //Phase-1 parallel build. Runs on a background queue (the document keeps the
    //main thread free to pump the progress panel). Partitioning:
    //
    //  - This method is the COORDINATOR. It lists the root's immediate entries,
    //    creates each immediate-child FSItem, and appends them to root._childs.
    //    The coordinator is the SOLE writer of root._childs.
    //  - For each immediate child that is a directory (and not a volume mount),
    //    it dispatches a WORKER onto a concurrent queue. Each worker is the SOLE
    //    writer of its own node and everything below it (a disjoint subtree),
    //    recursing SERIALLY within the worker (no per-node dispatch).
    //  - Counts are tallied per worker and merged after join; the globals are
    //    written once, here, on the coordinator.
    //
    //Throws FSItemError.loadingCanceled if progress.cancelled becomes true.
    //
    //Phase 2 (recalculateSize + kind statistics) is NOT done here; the caller
    //runs it on the main thread after this returns.
    private static let scanResourceKeys: [URLResourceKey] = [
        .nameKey,
        .isVolumeKey,
        .isPackageKey,
        .isDirectoryKey,
        .typeIdentifierKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey
    ]

    //Bound the number of concurrently dispatched top-level subdirectory workers
    //to the active processor count. Each worker descends serially, so this caps
    //the live thread count regardless of how many immediate subdirs the root has.
    func loadChildrenParallel(params: ScanParams, progress: ScanProgress) throws {
        if !isFolder() {
            return
        }

        _childs = []

        let selfURL = fileURL()!

        if progress.cancelled {
            throw FSItemError.loadingCanceled
        }
        progress.noteEnteredFolder(path: selfURL.cachedPath())

        //list the root's immediate entries (coordinator owns root._childs)
        let entries = try FSItem.directoryEntries(of: selfURL)

        //create immediate-child nodes serially on the coordinator. Counting the
        //root's own immediate files happens here.
        var coordinatorCounts = ScanCounts()
        var subdirWorkers: [FSItem] = []
        for entryURL in entries {
            entryURL.cacheResources(in: FSItem.scanResourceKeys)
            let child = FSItem(url: entryURL, parent: self,
                               setKindString: params.setKindStrings,
                               usePhysicalSize: params.usePhysicalSize,
                               counts: &coordinatorCounts)
            //descend into directory children, except volume mount points
            //(matches the serial walk, which skips volume descendants).
            if entryURL.isDirectory() && !entryURL.isVolume() {
                subdirWorkers.append(child)
            }
        }

        //dispatch one worker per immediate subdirectory; each fills its own
        //disjoint subtree. Bounded by a semaphore = activeProcessorCount - 1,
        //leaving one core for the main thread (modal-session pump + coordinator).
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.derlien.diskinventoryx.scan",
                                  attributes: .concurrent)
        let workerLimit = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        let semaphore = DispatchSemaphore(value: workerLimit)

        //Each worker scans its disjoint subtree with a worker-LOCAL ScanCounts,
        //then merges that local tally into the shared `merged` accumulator under
        //`mergeLock` exactly once (so the only shared mutation is a brief locked
        //add, not per-node). The first worker error is likewise recorded under
        //the lock. No node state is shared between workers.
        let mergeLock = UnfairLock()
        var merged = ScanCounts()
        var firstError: Error?

        for subdir in subdirWorkers {
            semaphore.wait()
            queue.async(group: group) {
                defer { semaphore.signal() }
                var localCounts = ScanCounts()
                do {
                    try subdir.scanSubtreeSerially(params: params,
                                                   progress: progress,
                                                   counts: &localCounts)
                    mergeLock.withLock { merged = merged + localCounts }
                } catch {
                    //surface the error and signal siblings to stop. The partial
                    //local tally is discarded (results are about to be torn down).
                    mergeLock.withLock {
                        if firstError == nil { firstError = error }
                    }
                    progress.cancelled = true
                }
            }
        }
        group.wait()

        //join complete. Surface the first worker error (cancel or failure).
        if let firstError = firstError { throw firstError }
        if progress.cancelled {
            throw FSItemError.loadingCanceled
        }

        //merge counts and publish the globals (coordinator-only write).
        let total = coordinatorCounts + merged
        g_fileCount += total.files
        g_folderCount += total.folders
    }

    //Worker body: recursively fill THIS node's subtree, serially. The receiver
    //is a directory node already created (with _childs == []) and owned solely
    //by this worker. No delegate calls, no global mutation; counts tally into
    //the inout `counts`.
    private func scanSubtreeSerially(params: ScanParams,
                                     progress: ScanProgress,
                                     counts: inout ScanCounts) throws {
        //cancel check at each directory boundary
        if progress.cancelled {
            throw FSItemError.loadingCanceled
        }

        let selfURL = fileURL()!
        progress.noteEnteredFolder(path: selfURL.cachedPath())

        let entries = try FSItem.directoryEntries(of: selfURL)

        //recurse into subdirectories after creating all children. We descend
        //children in listing order; final ordering is fixed up by the
        //main-thread recalculateSize(...) sort after join, so listing order
        //does not affect the final tree.
        for entryURL in entries {
            entryURL.cacheResources(in: FSItem.scanResourceKeys)
            let child = FSItem(url: entryURL, parent: self,
                               setKindString: params.setKindStrings,
                               usePhysicalSize: params.usePhysicalSize,
                               counts: &counts)
            if entryURL.isDirectory() && !entryURL.isVolume() {
                //serial descent within this worker (no dispatch below root)
                try child.scanSubtreeSerially(params: params,
                                              progress: progress,
                                              counts: &counts)
            }
        }
    }

    //Per-directory listing with the same prefetched resource keys the serial
    //walk uses. A fresh NSURL is produced per entry, so disjoint subtrees never
    //share a URL object (thread-confined resource cache). Errors enumerating a
    //subdirectory are swallowed (treated as empty), mirroring the serial
    //enumerator's errorHandler which continues past per-item errors.
    private static func directoryEntries(of dirURL: NSURL) throws -> [NSURL] {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: dirURL as URL,
                includingPropertiesForKeys: scanResourceKeys,
                options: [])
            return urls.map { $0 as NSURL }
        } catch {
            //a problem listing this directory: treat as empty (the serial
            //enumerator likewise continues past subdirectory errors).
            return []
        }
    }

    //MARK: ----------------- pasteboard support -----------------------

    @objc(supportedPasteboardTypes)
    func supportedPasteboardTypes() -> [NSPasteboard.PasteboardType] {
        //match the original ordering: Filenames, String, FileContents
        var types: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            .string,
            NSPasteboard.PasteboardType("NSFileContentsPboardType")
        ]

        let uti = fileURL()?.cachedUTI()

        func testType(_ testIdentifier: String, _ type: NSPasteboard.PasteboardType) {
            if let uti = uti, uti == testIdentifier {
                types.append(type)
            }
        }

        testType(UTIIdentifier.rtf, NSPasteboard.PasteboardType.rtf)
        testType(UTIIdentifier.rtfd, NSPasteboard.PasteboardType.rtfd)
        testType(UTIIdentifier.html, NSPasteboard.PasteboardType.html)
        testType(UTIIdentifier.pdf, NSPasteboard.PasteboardType.pdf)

        // add TIFF if this is an image
        if let uti = uti, FSItem.utiConformsToImage(uti) {
            types.append(NSPasteboard.PasteboardType.tiff)
        }

        return types
    }

    @objc(supportsPasteboardType:)
    func supportsPasteboardType(_ type: String) -> Bool {
        let uti = fileURL()?.cachedUTI()

        //this is derived from NTFilePasteboardSource's "- (NSArray*)pasteboardTypes:"
        return type == "NSFilenamesPboardType"
            || type == NSPasteboard.PasteboardType.string.rawValue
            || type == "NSFileContentsPboardType"
            || (type == NSPasteboard.PasteboardType.tiff.rawValue && uti != nil && FSItem.utiConformsToImage(uti!))
            || (type == NSPasteboard.PasteboardType.rtf.rawValue && uti == UTIIdentifier.rtf)
            || (type == NSPasteboard.PasteboardType.rtfd.rawValue && uti == UTIIdentifier.flatRTFD)
            || (type == NSPasteboard.PasteboardType.html.rawValue && uti == NSPasteboard.PasteboardType.html.rawValue)
            || (type == NSPasteboard.PasteboardType.pdf.rawValue && uti == NSPasteboard.PasteboardType.pdf.rawValue)
    }

    @objc(writeToPasteboard:)
    func writeToPasteboard(_ pboard: NSPasteboard) {
        pboard.declareTypes(supportedPasteboardTypes(), owner: self)
    }

    @objc(writeToPasteboard:withTypes:)
    func writeToPasteboard(_ pasteboard: NSPasteboard, withTypes types: [Any]) {
        let pbTypes = types.compactMap { ($0 as? String).map { NSPasteboard.PasteboardType($0) } }
        NTFilePasteboardSource.file(fileURL() as URL?, to: pasteboard, types: pbTypes)
    }

    @objc(pasteboard:provideDataForType:)
    func pasteboard(_ pboard: NSPasteboard, provideDataForType type: String) {
        guard let url = fileURL() else { return }
        let path = url.cachedPath()
        let uti = url.cachedUTI()

        if type == "NSFilenamesPboardType" {
            let pathsArray = [path as Any]
            pboard.setPropertyList(pathsArray, forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        } else if type == NSPasteboard.PasteboardType.string.rawValue {
            pboard.setString(path, forType: .string)
        } else if type == "NSFileContentsPboardType" {
            // write the contents
            pboard.writeFileContents(path)
        } else if type == NSPasteboard.PasteboardType.tiff.rawValue {
            if uti == UTIIdentifier.tiff {
                if let data = NSData(contentsOfFile: path) as Data? {
                    pboard.setData(data, forType: .tiff)
                }
            } else if let uti = uti, FSItem.utiConformsToImage(uti) {
                // open the image and return TIFFRepresentation
                if let image = NSImage(contentsOfFile: url.path ?? ""),
                   let data = image.tiffRepresentation {
                    pboard.setData(data, forType: .tiff)
                }
            }
        } else if type == NSPasteboard.PasteboardType.rtf.rawValue {
            if uti == UTIIdentifier.rtf, let data = NSData(contentsOfFile: path) as Data? {
                pboard.setData(data, forType: .rtf)
            }
        } else if type == NSPasteboard.PasteboardType.rtfd.rawValue {
            if uti == UTIIdentifier.flatRTFD {
                if let tempRTFDData = try? FileWrapper(url: URL(fileURLWithPath: path), options: []) {
                    pboard.setData(tempRTFDData.serializedRepresentation ?? Data(), forType: .rtfd)
                }
            }
        } else if type == NSPasteboard.PasteboardType.html.rawValue {
            if uti == UTIIdentifier.html, let data = NSData(contentsOfFile: path) as Data? {
                pboard.setData(data, forType: .html)
            }
        } else if type == NSPasteboard.PasteboardType.pdf.rawValue {
            if uti == UTIIdentifier.pdf, let data = NSData(contentsOfFile: path) as Data? {
                pboard.setData(data, forType: .pdf)
            }
        }
    }
}
