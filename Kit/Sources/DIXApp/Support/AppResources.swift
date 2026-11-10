//
//  AppResources.swift
//  DIXApp
//
//  The original app's images (toolbar icons and so on). In the .app they are in
//  Contents/Resources (copied there by scripts/make-app.sh); when running from
//  `swift build` / tests / the offscreen harness they are read straight from
//  Kit/App/Resources next to the sources.
//
//  GPL v3
//

import AppKit

public enum AppResources {
    /// Kit/App/Resources, found relative to this source file (development builds)
    static let sourceResources: URL = {
        URL(fileURLWithPath: #filePath)            // Kit/Sources/DIXApp/Support/AppResources.swift
            .deletingLastPathComponent()           // Support
            .deletingLastPathComponent()           // DIXApp
            .deletingLastPathComponent()           // Sources
            .deletingLastPathComponent()           // Kit
            .appendingPathComponent("App/Resources")
    }()

    private static var cache: [String: NSImage] = [:]

    /// An image by base name ("ZoomIn"), from the app bundle or the source tree.
    public static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        var image = Bundle.main.image(forResource: name)
        if image == nil {
            for ext in ["tiff", "png", "icns"] {
                let url = sourceResources.appendingPathComponent("\(name).\(ext)")
                if let i = NSImage(contentsOf: url) { image = i; break }
            }
        }
        if let image { cache[name] = image }
        return image
    }

    /// the app icon (bundle icon, or the source PNG during development)
    public static var appIcon: NSImage {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return NSApp?.applicationIconImage ?? NSImage()
        }
        let url = sourceResources.deletingLastPathComponent().appendingPathComponent("AppIcon.iconset/icon_256x256.png")
        return NSImage(contentsOf: url) ?? NSImage()
    }
}
