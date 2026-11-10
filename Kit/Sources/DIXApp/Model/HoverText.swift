//
//  HoverText.swift
//  DIXApp
//
//  The two status lines under the treemap, for what the mouse is over
//  (TreeMapViewController.treeMapViewItemTouched in the original):
//
//    report.pdf (Documents)                 name (folder)
//    PDF document, 1.2 MB                   kind, size
//
//  plus the cases the original didn't have: merged areas of small files,
//  cloud placeholders and hard links.
//
//  GPL v3
//

import DIXCore
import DIXTreemap
import Foundation

public struct StatusText: Equatable, Sendable {
    public var name: String
    public var detail: String
    public static let empty = StatusText(name: "", detail: "")
}

public enum HoverText {
    /// the text for a node (a file, or a folder or package drawn as one cell)
    public static func text(for node: NodeIndex, snapshot s: Snapshot, sizeMode: SizeMode) -> StatusText {
        var name = s.name(of: node)
        if node != Snapshot.root {
            let parent = Int(s.parent[node])
            var parentName = s.name(of: parent)
            if parent == Snapshot.root, FileManager.default.fileExists(atPath: s.rootPath) {
                parentName = FileManager.default.displayName(atPath: s.rootPath)
            }
            name += " (\(parentName))"
        }
        let flags = s.flags[node]
        let kind = flags.contains(.directory) && !flags.contains(.package) ? "Folder" : s.kind(of: node).name
        var detail = "\(kind), \(Format.size(s.size(of: node, mode: sizeMode)))"
        if flags.contains(.cloudPlaceholder) {
            detail += " — " + cloudNote(path: s.path(of: node), sizeMode: sizeMode, logical: s.logicalSize[node])
        } else if flags.contains(.hardLinkDuplicate) && sizeMode == .allocated {
            detail += " — another hard link to a file counted elsewhere"
        } else if flags.contains(.unreadable) {
            detail += " — couldn't be read"
        } else if flags.contains(.mountPoint) {
            detail += " — another volume is mounted here"
        }
        return StatusText(name: name, detail: detail)
    }

    /// "in iCloud, not on this Mac"
    public static func cloudNote(path: String, sizeMode: SizeMode, logical: UInt64) -> String {
        var note = "in \(cloudProvider(forPath: path)), not on this Mac"
        if sizeMode == .allocated && logical > 0 { note += " (\(Format.size(logical)) in the cloud)" }
        return note
    }

    /// the cloud service a placeholder belongs to, from where it lives
    public static func cloudProvider(forPath path: String) -> String {
        if path.contains("/Library/Mobile Documents/") { return "iCloud" }
        if let range = path.range(of: "/Library/CloudStorage/") {
            let folder = path[range.upperBound...].prefix { $0 != "/" }
            let service = folder.prefix { $0 != "-" }
            switch service.lowercased() {
            case "dropbox": return "Dropbox"
            case "onedrive": return "OneDrive"
            case "googledrive": return "Google Drive"
            case "box": return "Box"
            case "": break
            default: return String(service)
            }
        }
        if path.contains("/Dropbox/") { return "Dropbox" }
        return "the cloud"
    }

    /// the text for whatever is under the pointer
    public static func text(for hit: TreemapHit?, layout: TreemapLayout, pixelX: Int, pixelY: Int) -> StatusText {
        guard let hit else { return .empty }
        let s = layout.model.snapshot
        switch hit {
        case .node(let node, _):
            return text(for: node, snapshot: s, sizeMode: layout.model.sizeMode)
        case .merged(let group, _):
            let breakdown = layout.breakdown(atPixelX: pixelX, y: pixelY) ?? layout.breakdown(of: group)
            return mergedText(breakdown, folderName: s.name(of: group.folder))
        case .freeSpace:
            return StatusText(name: "free space on drive", detail: Format.size(s.volume?.availableCapacity ?? 0))
        case .otherSpace:
            let v = s.volume
            let used = (v?.totalCapacity ?? 0) &- (v?.availableCapacity ?? 0)
            let shown = layout.model.size(of: layout.root)
            let other = used > shown ? used - shown : 0
            return StatusText(name: "space occupied by other files and folders", detail: Format.size(other))
        }
    }

    /// "70 small files in 1 folder: 35 JavaScript, 20 JSON, … (node_modules)" / "14 MB"
    public static func mergedText(_ b: MergedBreakdown, folderName: String) -> StatusText {
        // DIXTreemap's summary, with kinds of the same name (different types) counted together
        var byName: [MergedBreakdown.KindShare] = []
        for k in b.kinds {
            if let i = byName.firstIndex(where: { $0.name == k.name }) {
                byName[i].count += k.count
                byName[i].size &+= k.size
            } else {
                byName.append(k)
            }
        }
        byName.sort { $0.size > $1.size }
        var merged = b
        merged.kinds = byName
        var summary = merged.summary()
        if let r = summary.range(of: " · ", options: .backwards) { summary = String(summary[..<r.lowerBound]) }
        return StatusText(name: "\(summary) (\(folderName))", detail: Format.size(b.size))
    }
}
