//
//  MainMenu.swift
//  DIXApp
//
//  The menu bar, as the original's MainMenu.nib: Disk Inventory X, File, Edit,
//  View, Window, Help, with the same items, order and shortcuts. Additions:
//  File > Save Scan… (⌘S).
//
//  GPL v3
//

import AppKit

enum MainMenu {
    static func build(appDelegate: AppDelegate) -> NSMenu {
        let main = NSMenu(title: "MainMenu")
        func submenu(_ title: String) -> NSMenu {
            let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: String?, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command, tip: String? = nil, target: AnyObject? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action.map { Selector($0) }, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.toolTip = tip
            item.target = target
            return item
        }

        // application menu
        let app = submenu("Disk Inventory X")
        _ = add(app, "About Disk Inventory X", "orderFrontStandardAboutPanel:")
        app.addItem(.separator())
        _ = add(app, "Preferences...", "showPreferencesPanel:", ",", target: appDelegate)
        app.addItem(.separator())
        let services = app.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        app.addItem(.separator())
        _ = add(app, "Hide Disk Inventory X", "hide:", "h")
        _ = add(app, "Hide Others", "hideOtherApplications:", "h", [.command, .option])
        _ = add(app, "Show All", "unhideAllApplications:")
        app.addItem(.separator())
        _ = add(app, "Quit Disk Inventory X", "terminate:", "q")

        // File
        let file = submenu("File")
        _ = add(file, "Open Folder...", "openDocument:", "o")
        let recent = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        _ = add(recentMenu, "Clear Menu", "clearRecentDocuments:")
        recent.submenu = recentMenu
        let setName = Selector(("_setMenuName:"))
        if recentMenu.responds(to: setName) { recentMenu.perform(setName, with: "NSRecentDocumentsMenu") }
        file.addItem(.separator())
        _ = add(file, "Close", "performClose:", "w")
        _ = add(file, "Save Scan...", "saveScan:", "s", tip: "Save the scan to look at it again later without rescanning")
        file.addItem(.separator())
        _ = add(file, "Reveal in Finder", "showInFinder:", "F", tip: "Reveal the selected file or folder in the Finder")
        _ = add(file, "Refresh Selection", "refresh:", tip: "Synchronize selected folder or file with Finder")
        _ = add(file, "Refresh All", "refreshAll:", tip: "Synchronize window with Finder")
        file.addItem(.separator())
        _ = add(file, "Move To Trash", "moveToTrash:", "\u{8}", tip: "Move the selected file or folder to the trash")

        // Edit
        let edit = submenu("Edit")
        _ = add(edit, "Undo", "undo:", "z")
        _ = add(edit, "Redo", "redo:", "Z")
        edit.addItem(.separator())
        _ = add(edit, "Cut", "cut:", "x")
        _ = add(edit, "Copy", "copy:", "c")
        _ = add(edit, "Paste", "paste:", "v")
        _ = add(edit, "Delete", "delete:")
        _ = add(edit, "Select All", "selectAll:", "a")

        // View
        let view = submenu("View")
        let zoomIn = add(view, "Zoom In", "zoomIn:", "+", tip: "Zoom in selected folder")
        zoomIn.tag = 3
        _ = add(view, "Zoom Out", "zoomOut:", "-", tip: "Zoom out to previous folder")
        let zoomTo = view.addItem(withTitle: "Zoom Out To", action: nil, keyEquivalent: "")
        let zoomToMenu = NSMenu(title: "Zoom Out To")
        zoomToMenu.delegate = appDelegate
        zoomTo.submenu = zoomToMenu
        appDelegate.zoomStackMenu = zoomToMenu
        view.addItem(.separator())
        _ = add(view, "Select Parent Folder", "selectParentItem:", "u")
        view.addItem(.separator())
        _ = add(view, "Show Free Space", "showFreeSpace:", tip: "Show free space on volume in the treemap")
        _ = add(view, "Show Other Space", "showOtherSpace:", tip: "Show space occupied by not shown files/folders in the tree map")
        view.addItem(.separator())
        _ = add(view, "Show Package Contents", "showPackageContents:", tip: "Show packages like folders or files")
        _ = add(view, "Show Physical File Size", "showPhysicalSizes:", tip: "Show the physical or logical file size")
        view.addItem(.separator())
        _ = add(view, "Split Horizontally", "changeSplitting:", tip: "Switch between the window's horizontal and vertical splitting")
        view.addItem(.separator())
        _ = add(view, "Hide Toolbar", "toggleToolbarShown:")
        _ = add(view, "Customize Toolbar...", "runToolbarCustomizationPalette:")

        // Window
        let window = submenu("Window")
        _ = add(window, "File Kind Statistics", "toggleFileKindsDrawer:", tip: "Show/hide the file kind statistic drawer")
        _ = add(window, "Selection List", "toggleSelectionListDrawer:")
        window.addItem(.separator())
        _ = add(window, "Information", "showInformationPanel:", "i", tip: "Show/hide the information window")
        window.addItem(.separator())
        _ = add(window, "Minimize", "performMiniaturize:", "m")
        _ = add(window, "Bring All to Front", "arrangeInFront:")
        NSApp.windowsMenu = window

        // Help
        let help = submenu("Help")
        _ = add(help, "Disk Inventory X Help", "showHelp:", "?")
        _ = add(help, "Visit Disk Inventory X Website", "gotoHomepage:", target: appDelegate)
        NSApp.helpMenu = help
        return main
    }
}
