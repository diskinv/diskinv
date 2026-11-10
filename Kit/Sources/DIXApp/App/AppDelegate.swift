//
//  AppDelegate.swift
//  DIXApp
//
//  Launch (the drives panel first, as the original), opening folders and
//  saved scans from the Finder, the Zoom Out To menu, Preferences.
//
//  GPL v3
//

import AppKit
import DIXCore

public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    weak var zoomStackMenu: NSMenu?
    private var preferences: PreferencesWindowController?

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(appDelegate: self)
        // the drives panel comes up before any document (e.g. one dropped on the Dock icon)
        DrivesPanelController.shared.show()
    }

    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { DrivesPanelController.shared.show() }
        return true
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    var currentWindowController: DocumentWindowController? {
        (NSApp.mainWindow?.windowController as? DocumentWindowController)
            ?? (NSDocumentController.shared.currentDocument as? ScanDocument)?.windowController
    }

    /// View > Zoom Out To: the zoom stack, root first
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === zoomStackMenu else { return }
        menu.removeAllItems()
        guard let wc = currentWindowController else { return }
        let model = wc.model
        let s = model.snapshot
        var icons = IconCache()
        for (i, node) in model.zoomStack.enumerated() {
            let item = menu.addItem(withTitle: i == 0 ? (ScanDocument.displayName(forRoot: s) ?? s.name(of: node)) : s.name(of: node),
                                    action: #selector(DocumentWindowController.zoomOutTo(_:)), keyEquivalent: "")
            item.representedObject = node
            item.image = icons.icon(for: node, in: s)
            if i > 0 { item.toolTip = (s.path(of: node) as NSString).abbreviatingWithTildeInPath }
        }
    }

    @objc func showPreferencesPanel(_ sender: Any?) {
        if preferences == nil { preferences = PreferencesWindowController() }
        preferences?.showWindow(nil)
    }

    @objc func gotoHomepage(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://www.derlien.com")!)
    }
}

public enum DIXApplication {
    /// runs the app (the executable's main)
    public static func main() {
        let app = NSApplication.shared
        _ = DocumentController()      // the first one made becomes the shared document controller
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
