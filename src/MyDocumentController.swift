//
//  MyDocumentController.swift
//  Disk Inventory Xs
//
//  Swift port of MyDocumentController.{h,m}. This is the app's NSDocumentController
//  subclass and (via MainMenu.nib) its NSApplicationDelegate. It must keep the exact
//  class name `MyDocumentController` (the nib instantiates it as the shared document
//  controller) and pin every nib-wired outlet/action selector with @objc.
//
//  Two deviations from a 1:1 port, both forced by Swift:
//
//   1. The ObjC `-typeFromFileExtension:` override (which mapped non-HFS extensions
//      to the "Folder" doc type) is DROPPED: NSDocumentController.typeFromFileExtension:
//      is marked @available(*, unavailable) in Swift and cannot be overridden. The
//      folder -> "Folder" doc-type mapping is preserved by makeDocument(withContentsOf:
//      ofType:) below, which already detects directories and re-dispatches to super with
//      ofType: "Folder" — so document opening of folders still works without it.
//
//  GPL v3
//

import Cocoa

@objc(MyDocumentController)
class MyDocumentController: NSDocumentController {

    @IBOutlet private var _zoomStackMenu: NSMenu!
    @IBOutlet private var _donationPanel: NSPanel!
    private var _donationPanelNibTopLevelObjects: [Any]?

    // MARK: - open panel

    override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        //we want the user to choose a directory (including packages)
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.treatsFilePackagesAsDirectories = true

        //volumes panel isn't (yet) loaded, so show the open panel the normal way (as a modal window)
        return openPanel.runModal().rawValue
    }

    @objc(openPanelDidEnd:returnCode:contextInfo:)
    func openPanelDidEnd(_ sheet: NSOpenPanel, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        if returnCode == NSApplication.ModalResponse.OK.rawValue {
            //open selected folders
            for fileURL in sheet.urls {
                //defer it till the next loop cycle to let the sheet closes itself first
                let path = fileURL.path
                DispatchQueue.main.async { [weak self] in
                    self?.openDocument(withContentsOfFile: path)
                }
            }
        }
    }

    //calls "openDocumentWithContentsOfURL: display: completionHandler:"
    @objc(openDocumentWithContentsOfFile:)
    func openDocument(withContentsOfFile fileName: String) {
        openDocument(withContentsOf: URL(fileURLWithPath: fileName),
                     display: true,
                     completionHandler: { _, _, _ in })
    }

    @objc(applicationShouldOpenUntitledFile:)
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        //we don't want any untitled document as we need an existing folder
        return false
    }

    //
    // Modern (10.5+) replacement for the deprecated -typeFromFileExtension: override
    // that the ObjC class used. NSDocumentController calls this to resolve a URL to a
    // document type during opening; the ObjC version overrode -typeFromFileExtension:
    // to return the "Folder" type for any non-HFS extension. -typeFromFileExtension:
    // is @available(*, unavailable) in Swift and cannot be overridden, but this
    // documented successor IS overridable — and it is the call that determines the
    // doc type, so without it Cocoa resolves a folder to the generic "Document" type
    // and refuses to open it. Map directories to "Folder", everything else to super.
    //
    override func typeForContents(of url: URL) throws -> String {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDir {
            return "Folder"
        }
        return try super.typeForContents(of: url)
    }

    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        //check whether "url" is a folder
        if let attribs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            let type = attribs[.type] as? FileAttributeType
            if type == .typeDirectory {
                return try super.makeDocument(withContentsOf: url, ofType: "Folder")
            }
        }

        //not a folder: replicate the ObjC version which returned nil (-> Cocoa reports
        //the document couldn't be opened). In the throwing Swift variant we raise the
        //equivalent error rather than returning nil.
        throw NSError(domain: NSCocoaErrorDomain,
                      code: CocoaError.fileReadUnknown.rawValue,
                      userInfo: nil)
    }

    //"Open..." menu handler
    @objc(openDocument:)
    override func openDocument(_ sender: Any?) {
        //we implement this method by ourself, so we can avoid that stupid message "document couldn't be opened"
        //in the case the user canceled the opening
        guard let fileNames = urlsFromRunningOpenPanel() else {
            return //cancel pressed in open panel
        }

        for dir in fileNames {
            openDocument(withContentsOf: dir,
                         display: true,
                         completionHandler: { _, _, _ in })
        }
    }

    override class func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier,
                                      state: NSCoder,
                                      completionHandler: @escaping (NSWindow?, Error?) -> Void) {
        // prevent any window, which was open when quitting the app last time, to be re-opened now at the next launch
        // (see the Document-Based App Programming Guide for Mac / Core App Behaviors / Windows Are Restored Automatically)
        completionHandler(nil, nil)
    }

    //Application's delegate; called if file from recent list is selected
    @objc(application:openFile:)
    func application(_ theApp: NSApplication, openFile fileName: String) -> Bool {
        //if "fileName" doesn't exist or isn't a folder, return NO so that it is removed from the recent list
        guard let attribs = try? FileManager.default.attributesOfItem(atPath: fileName),
              (attribs[.type] as? FileAttributeType) == .typeDirectory else {
            return false
        }

        openDocument(withContentsOfFile: fileName)

        //return TRUE to avoid nasty message if user canceled loading
        return true
    }

    @IBAction func gotoHomepage(_ sender: Any?) {
        if let url = URL(string: "http://www.derlien.com") {
            NSWorkspace.shared.open(url)
        }
    }

    @IBAction func closeDonationPanel(_ sender: Any?) {
        _donationPanel?.close() //just hides; ownership stays with _donationPanelNibTopLevelObjects
        _donationPanel = nil
    }

    // MARK: - app notifications

    @objc(applicationWillFinishLaunching:)
    func applicationWillFinishLaunching(_ notification: Notification) {
        //verify that our custom DocumentController is in use
        assert(NSDocumentController.shared is MyDocumentController,
               "the shared DocumentController is not our custom class!")

        //show the drives panel before "applicationDidFinishLaunching" so the panel is visible before the first document is loaded
        //(e.g. through drag&drop)
        DrivesPanelController.sharedController.showPanel()
    }

    @objc(applicationSupportsSecureRestorableState:)
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    @objc(applicationDidFinishLaunching:)
    func applicationDidFinishLaunching(_ notification: Notification) {
        //show donate message
        if !UserDefaults.standard.bool(forKey: DontShowDonationMessage) {
            var topLevelObjects: NSArray?
            Bundle.main.loadNibNamed("DonationPanel", owner: self, topLevelObjects: &topLevelObjects)
            _donationPanelNibTopLevelObjects = topLevelObjects as? [Any]

            //the nib has "release when closed = YES"; turn it off so the panel's
            //lifetime is governed by _donationPanelNibTopLevelObjects only. Otherwise
            //closing the panel frees it while the array still holds a stale pointer,
            //producing a zombie -release crash later on pool drain.
            _donationPanel?.isReleasedWhenClosed = false
            _donationPanel?.worksWhenModal = true
        }
    }

    // MARK: - NSMenu delegate

    @objc(menuNeedsUpdate:)
    func menuNeedsUpdate(_ zoomStackMenu: NSMenu) {
        assert(_zoomStackMenu == zoomStackMenu)

        let doc = currentDocument as? FileSystemDoc
        //thanks to nil-safety, the zoomStack is empty if there is no current doc
        let zoomStack = doc?.zoomStack() ?? []

        //rebuild the whole menu from the zoom stack: item 0 is the root item,
        //items 1..N correspond to zoomStack[i-1]
        zoomStackMenu.items = (0..<zoomStack.count).map { i in
            let fsItem: FSItem?
            if i == 0 {
                fsItem = doc?.rootItem()
            } else {
                fsItem = zoomStack[i - 1] as? FSItem
            }

            let menuItem = NSMenuItem()
            menuItem.title = fsItem?.displayName() ?? ""
            if i > 0 { //no tooltip for first item as the tooltip is the same as the title
                menuItem.toolTip = fsItem?.displayPath()
            }
            menuItem.image = fsItem?.icon(withSize: 16)
            menuItem.representedObject = fsItem
            menuItem.target = nil
            menuItem.action = NSSelectorFromString("zoomOutTo:")
            return menuItem
        }
    }
}
