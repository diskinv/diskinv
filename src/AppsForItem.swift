//
//  AppsForItem.swift
//  Disk Inventory Xs
//
//  Swift port of AppsForItem.{h,m}. Finds the default and additional
//  applications that can open a file/folder via LaunchServices. Backed by
//  the NSURL-Extensions ObjC category (exposed via the bridging header).
//
//  GPL v3
//

import Cocoa
import CoreServices

@objc(AppsForItem)
final class AppsForItem: NSObject {

    @objc let itemURL: NSURL

    @objc(initWithItemURL:)
    init(itemURL: NSURL) {
        self.itemURL = itemURL
        super.init()
    }

    @objc(appsForItemURL:)
    class func appsForItem(_ url: NSURL) -> AppsForItem {
        AppsForItem(itemURL: url)
    }

    private static let roleMask: LSRolesMask = [.viewer, .editor]

    // MARK: - default application (may return nil)

    private var defaultAppComputed = false
    private var _defaultAppURL: NSURL?

    @objc var defaultAppURL: NSURL? {
        if !defaultAppComputed {
            defaultAppComputed = true
            let appURL: NSURL?
            if #available(macOS 12.0, *) {
                appURL = NSWorkspace.shared.urlForApplication(toOpen: itemURL as URL) as NSURL?
            } else {
                appURL = LSCopyDefaultApplicationURLForURL(itemURL as CFURL, Self.roleMask, nil)?
                    .takeRetainedValue() as NSURL?
            }
            guard let appURL = appURL
            else { return nil }
            if check(appURL: appURL, checkDefaultApp: false) {
                _defaultAppURL = appURL
            }
        }
        return _defaultAppURL
    }

    // MARK: - additional applications (may be empty, never nil)

    private var _additionalAppURLs: [NSURL]?

    @objc var additionalAppURLs: [NSURL] {
        if _additionalAppURLs == nil {
            let appURLs = Self.applicationURLs(forItemURL: itemURL)
            var result = appURLs.filter { $0.isFileURL && check(appURL: $0, checkDefaultApp: true) }
            result.sort { $0.name().caseInsensitiveCompare($1.name()) == .orderedAscending }
            _additionalAppURLs = result
        }
        return _additionalAppURLs!
    }

    // MARK: - opening

    @objc(openItemWithAppURL:)
    func openItem(withAppURL appURL: NSURL) {
        Self.openItem(url: itemURL, withAppURL: appURL)
    }

    @objc(openItemURL:withAppURL:)
    class func openItem(url itemURL: NSURL, withAppURL appURL: NSURL) {
        if #available(macOS 10.15, *) {
            NSWorkspace.shared.open(
                [itemURL as URL],
                withApplicationAt: appURL as URL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.openFile(itemURL.path ?? "", withApplication: appURL.path)
        }
    }

    // MARK: - private

    private func check(appURL: NSURL, checkDefaultApp: Bool) -> Bool {
        if checkDefaultApp, let def = defaultAppURL, appURL.isEqual(to: def as URL) {
            return false
        }

        let isDIX = appURL.name() == "Disk Inventory X.app"
        let isFinder = appURL.name() == "Finder.app"

        // filter out the Finder (returned for simple folders by LaunchServices)
        return !isDIX && (appURL.isFile() || appURL.isPackage() || !isFinder)
    }

    // NOTE: this searches network volumes
    private class func applicationURLs(forItemURL itemURL: NSURL) -> [NSURL] {
        if #available(macOS 12.0, *) {
            let urls = NSWorkspace.shared.urlsForApplications(toOpen: itemURL as URL)

            // filter out .exe files
            return urls
                .filter {
                    ($0.path as NSString).pathExtension.caseInsensitiveCompare("exe") != .orderedSame
                }
                .map { $0 as NSURL }
        } else {
            guard let urls = LSCopyApplicationURLsForURL(itemURL as CFURL, roleMask)?
                .takeRetainedValue() as? [NSURL]
            else { return [] }

            // filter out .exe files
            return urls.filter {
                ($0.path as NSString?)?.pathExtension.caseInsensitiveCompare("exe") != .orderedSame
            }
        }
    }
}
