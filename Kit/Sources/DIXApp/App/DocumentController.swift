//
//  DocumentController.swift
//  DIXApp
//
//  Opening things (MyDocumentController in the original): a folder is
//  scanned in the background with the progress panel, then shown; a saved
//  scan (.dixsnap) is read and shown right away. Open Folder… takes either.
//
//  GPL v3
//

import AppKit
import DIXCore
import DIXScan
import UniformTypeIdentifiers

public final class DocumentController: NSDocumentController {
    /// folders being scanned (so the same folder isn't scanned twice at once)
    private var scanning: [String: ScanOperation] = [:]

    static func isSavedScan(_ url: URL) -> Bool { url.pathExtension.lowercased() == "dixsnap" }

    static func isFolder(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue && !isSavedScan(url)
    }

    public override func documentClass(forType typeName: String) -> AnyClass? { ScanDocument.self }
    public override var defaultType: String? { ScanDocument.scanType }
    public override var documentClassNames: [String] { ["ScanDocument"] }

    public override func typeForContents(of url: URL) throws -> String {
        if Self.isSavedScan(url) { return ScanDocument.scanType }
        if Self.isFolder(url) { return ScanDocument.folderType }
        return try super.typeForContents(of: url)
    }

    public override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                                      completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        if Self.isFolder(url) {
            scanFolder(url, completion: completionHandler)
            return
        }
        super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
    }

    /// Scans a folder and opens a window for it (or brings an open one forward).
    public func scanFolder(_ url: URL, completion: ((NSDocument?, Bool, Error?) -> Void)? = nil) {
        let url = url.standardizedFileURL
        if let open = documents.first(where: { ($0 as? ScanDocument)?.isSavedScan == false && $0.fileURL?.standardizedFileURL == url }) {
            open.showWindows()
            completion?(open, true, nil)
            return
        }
        if let running = scanning[url.path] {
            running.progressPanel.panel.makeKeyAndOrderFront(nil)
            return
        }
        let op = ScanOperation(url: url)
        scanning[url.path] = op
        op.progressPanel.onCancel = { [weak self, weak op] in
            op?.cancel()
            self?.scanning[url.path] = nil
        }
        op.start { [weak self] result in
            guard let self else { return }
            self.scanning[url.path] = nil
            switch result {
            case .success(let scan):
                let doc = ScanDocument(scan: scan, folderURL: url)
                self.addDocument(doc)
                doc.makeWindowControllers()
                doc.showWindows()
                self.noteNewRecentDocument(doc)
                completion?(doc, false, nil)
            case .failure(let error):
                self.presentError(error)
                completion?(nil, false, error)
            }
        }
        // start() set its own cancel handler; keep ours on top of it
        op.progressPanel.onCancel = { [weak self, weak op] in
            op?.cancel()
            self?.scanning[url.path] = nil
        }
    }

    /// Open Folder…: folders (packages too) and saved scans
    public override func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = true
        panel.allowedContentTypes = [.folder, .directory, ScanDocument.scanUTType]
        panel.message = "Choose a folder to scan, or a saved scan (.dixsnap) to open."
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    /// never reopen windows from the last session (that would rescan folders at launch)
    public override class func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                                             completionHandler: @escaping (NSWindow?, Error?) -> Void) {
        completionHandler(nil, nil)
    }

    public override func noteNewRecentDocument(_ document: NSDocument) {
        if let url = document.fileURL { noteNewRecentDocumentURL(url) }
    }
}
