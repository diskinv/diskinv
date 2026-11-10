//
//  ScanDocument.swift
//  DIXApp
//
//  One scanned folder (FileSystemDoc in the original): a scan made just now,
//  or a saved scan (.dixsnap) opened from disk. The document is a viewer: it is
//  never "edited", and Save Scan writes a .dixsnap of what is on screen.
//
//  GPL v3
//

import AppKit
import DIXCore
import DIXScan
import UniformTypeIdentifiers

@objc(ScanDocument)
public final class ScanDocument: NSDocument {
    static let folderType = "Folder"
    static let scanType = "com.derlien.diskinventoryx.dixsnap"
    static let scanUTType = UTType(exportedAs: scanType, conformingTo: .data)

    public private(set) var model: DocumentModel!
    /// the scan's problems (folders that couldn't be read), for the window's note
    public private(set) var unreadableFolders = 0
    /// true when the document came from a .dixsnap file
    public private(set) var isSavedScan = false

    public override init() {
        super.init()
        hasUndoManager = false
    }

    /// a document for a scan just made
    public convenience init(scan: ScanResult, folderURL: URL) {
        self.init()
        model = DocumentModel(snapshot: scan.snapshot, options: .fromDefaults())
        unreadableFolders = scan.summary.unreadableFolders
        fileURL = folderURL
        fileType = Self.folderType
    }

    /// a document showing a snapshot (tests, offscreen rendering)
    public convenience init(snapshot: Snapshot, options: ViewOptions = ViewOptions(), savedScan: URL? = nil) {
        self.init()
        model = DocumentModel(snapshot: snapshot, options: options)
        if let savedScan {
            isSavedScan = true
            fileURL = savedScan
            fileType = Self.scanType
        } else {
            fileURL = URL(fileURLWithPath: snapshot.rootPath)
            fileType = Self.folderType
        }
    }

    // MARK: reading .dixsnap

    public override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }
    public override class var autosavesInPlace: Bool { false }
    public override class var readableTypes: [String] { [scanType, folderType] }
    public override class var writableTypes: [String] { [scanType] }
    public override class func isNativeType(_ type: String) -> Bool { type == scanType }

    public override func read(from url: URL, ofType typeName: String) throws {
        guard typeName == Self.scanType || url.pathExtension == "dixsnap" else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let snapshot = try Snapshot(contentsOf: url)
        let model = DocumentModel(snapshot: snapshot, options: .fromDefaults())
        // build the treemap model now, while still off the main thread
        _ = model.treemapModel
        _ = model.kindStatistics
        self.model = model
        isSavedScan = true
    }

    public override func data(ofType typeName: String) throws -> Data {
        throw CocoaError(.fileWriteUnknown)   // saving goes through saveScan(_:)
    }

    public override var isDocumentEdited: Bool { false }

    public override var displayName: String! {
        get { Self.displayName(forRoot: model?.snapshot) ?? super.displayName }
        set { super.displayName = newValue }
    }

    static func displayName(forRoot s: Snapshot?) -> String? {
        guard let s else { return nil }
        if s.rootPath == "/" || s.rootPath == s.volume?.mountPath, let name = s.volume?.name, !name.isEmpty { return name }
        if FileManager.default.fileExists(atPath: s.rootPath) { return FileManager.default.displayName(atPath: s.rootPath) }
        return (s.rootPath as NSString).lastPathComponent
    }

    public override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    public var windowController: DocumentWindowController? {
        windowControllers.first as? DocumentWindowController
    }

    // MARK: saving

    /// File > Save Scan…: writes what is on screen as a .dixsnap
    @IBAction func saveScan(_ sender: Any?) {
        guard let window = windowController?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.scanUTType]
        panel.nameFieldStringValue = (displayName ?? "Scan") + ".dixsnap"
        panel.message = "Save the scan of “\(displayName ?? "")” to look at it again later without rescanning."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.model.snapshot.write(to: url)
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            } catch {
                self.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
            }
        }
    }

    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(saveScan(_:)) { return model != nil }
        return super.validateUserInterfaceItem(item)
    }
}
