//
//  TreemapHitTest.swift
//  DIXTreemap
//
//  Point -> cell, and node -> cell, on a layout.
//
//  GPL v3
//

import CoreGraphics
import DIXCore
import Foundation

extension TreemapLayout {
    /// The drawn cell under a backing-pixel position (origin top left), or nil outside.
    public func cellIndex(atPixelX x: Int, y: Int) -> Int? {
        guard !cellData.isEmpty else { return nil }
        var index = 0
        var c = cellData[0]
        guard x >= Int(c.x0), x < Int(c.x1), y >= Int(c.y0), y < Int(c.y1) else { return nil }
        while c.childCount > 0 {
            var next = -1
            let first = Int(c.firstChild)
            for i in first ..< first + Int(c.childCount) {
                let d = cellData[i]
                if x >= Int(d.x0) && x < Int(d.x1) && y >= Int(d.y0) && y < Int(d.y1) { next = i; break }
            }
            if next < 0 { return index }   // can't happen: children tile their parent
            index = next
            c = cellData[next]
        }
        return index
    }

    /// What is under a backing-pixel position (origin top left).
    public func hitTest(pixelX x: Int, y: Int) -> TreemapHit? {
        guard let index = cellIndex(atPixelX: x, y: y) else { return nil }
        return hit(forCell: index)
    }

    /// What is under a point in view coordinates (points, origin top left).
    public func hitTest(point: CGPoint) -> TreemapHit? {
        let x = (Double(point.x) * scale).rounded(.down), y = (Double(point.y) * scale).rounded(.down)
        guard x.isFinite, y.isFinite, abs(x) < 1e9, abs(y) < 1e9 else { return nil }
        return hitTest(pixelX: Int(x), y: Int(y))
    }

    public func hit(forCell index: Int) -> TreemapHit {
        let c = cellData[index]
        switch c.role {
        case .merged, .mergedPart: return .merged(mergedGroups[Int(c.group)], cell: index)
        case .freeSpace: return .freeSpace(cell: index)
        case .otherSpace: return .otherSpace(cell: index)
        case .container, .item: return .node(Int(c.node), cell: index)
        }
    }

    /// The cell showing a node: its own cell, or the merged cell it (or an
    /// ancestor) was merged into, or the package cell it is inside. nil when
    /// the node is not under the layout root or has no pixels.
    public func cellIndex(for node: NodeIndex) -> Int? {
        let snapshot = model.snapshot
        guard node >= 0, node < snapshot.nodeCount, !cellData.isEmpty else { return nil }
        // the path from the layout root down to the node
        var path: [Int] = []
        var current = node
        var steps = 0
        while current != root {
            path.append(current)
            if current == Snapshot.root || steps > snapshot.nodeCount { return nil }
            current = Int(snapshot.parent[current])
            steps += 1
        }
        var index = 0
        for target in path.reversed() {
            let c = cellData[index]
            guard c.role == .container else { return index }   // inside a package (or file) cell
            let first = Int(c.firstChild)
            var next = -1
            for i in first ..< first + Int(c.childCount) {
                let d = cellData[i]
                if d.role == .merged {
                    let group = mergedGroups[Int(d.group)]
                    if mergedMembers[group.members].contains(UInt32(target)) { return i }
                } else if Int(d.node) == target && d.role != .freeSpace && d.role != .otherSpace {
                    next = i
                    break
                }
            }
            if next < 0 { return nil }
            index = next
        }
        return index
    }

    /// The pixel rect showing a node (see `cellIndex(for:)`).
    public func rect(for node: NodeIndex) -> PixelRect? {
        cellIndex(for: node).map { cell($0).rect }
    }

    /// The rect showing a node in view coordinates (points, origin top left).
    public func pointRect(for node: NodeIndex) -> CGRect? {
        guard let r = rect(for: node) else { return nil }
        return CGRect(x: Double(r.x) / scale, y: Double(r.y) / scale,
                      width: Double(r.width) / scale, height: Double(r.height) / scale)
    }
}

// MARK: - describing merged areas

/// What a merged area holds, for hover text: counts and bytes per kind over the
/// merged items' whole subtrees.
public struct MergedBreakdown: Sendable, Hashable {
    public struct KindShare: Sendable, Hashable {
        public var kind: Int
        public var name: String
        public var count: Int
        public var size: UInt64
    }
    /// files (and packages drawn as one cell) inside
    public var fileCount: Int
    /// folders inside (including merged folders themselves)
    public var folderCount: Int
    /// total size, in the layout's size mode
    public var size: UInt64
    /// per kind, largest first
    public var kinds: [KindShare]

    /// e.g. "1,204 small files: 812 JavaScript, 300 JSON, … 14 MB"
    public func summary(maxKinds: Int = 3) -> String {
        let number = NumberFormatter()
        number.numberStyle = .decimal
        func n(_ v: Int) -> String { number.string(from: NSNumber(value: v)) ?? "\(v)" }
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
        var text = "\(n(fileCount)) small \(fileCount == 1 ? "file" : "files")"
        if folderCount > 0 { text += " in \(n(folderCount)) \(folderCount == 1 ? "folder" : "folders")" }
        let shown = kinds.prefix(maxKinds).map { "\(n($0.count)) \($0.name)" }
        if !shown.isEmpty { text += ": " + shown.joined(separator: ", ") + (kinds.count > maxKinds ? ", …" : "") }
        return text + " · " + bytes
    }
}

extension TreemapLayout {
    /// Counts what a merged group holds, walking the merged items' subtrees.
    /// With `colorSlot`, only kinds drawn in that color count (the part of a
    /// `kinds` / `kinds-texture` area under the pointer).
    public func breakdown(of group: MergedGroup, colorSlot: Int? = nil) -> MergedBreakdown {
        let s = model.snapshot
        var perKind: [Int: (count: Int, size: UInt64)] = [:]
        var files = 0, folders = 0
        var size: UInt64 = 0
        var stack = mergedMembers(of: group)
        while let n = stack.popLast() {
            if model.isContainer(n) {
                folders += 1
                stack.append(contentsOf: TreemapModel.childRange(s, n))
                continue
            }
            if s.isDirectory(n) && !s.flags[n].contains(.package) { folders += 1; continue }   // empty folder
            let k = Int(s.kindIndex[n])
            if let slot = colorSlot, model.kindColors.slot(ofKind: k) != slot { continue }
            files += 1
            let bytes = model.sizes[n]
            size &+= bytes
            perKind[k, default: (0, 0)].count += 1
            perKind[k, default: (0, 0)].size &+= bytes
        }
        let kinds = perKind.map { MergedBreakdown.KindShare(kind: $0.key, name: s.kinds[$0.key].name, count: $0.value.count, size: $0.value.size) }
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.kind < $1.kind }
        return MergedBreakdown(fileCount: files, folderCount: folders, size: size, kinds: kinds)
    }

    /// The breakdown for whatever merged area is under a pixel (nil when it's not merged).
    public func breakdown(atPixelX x: Int, y: Int) -> MergedBreakdown? {
        guard let index = cellIndex(atPixelX: x, y: y) else { return nil }
        let c = cellData[index]
        guard c.group >= 0 else { return nil }
        let group = mergedGroups[Int(c.group)]
        // a per-color cell (or a tile in one) narrows to its color; the mixed
        // "other" cell and the mixed tiles of `texture` describe the whole group
        var slot: Int? = nil
        if c.role == .mergedPart && options.mergedCellStyle != .texture {
            let parentIsPart = c.parent >= 0 && cellData[Int(c.parent)].role == .mergedPart
            let part = parentIsPart ? cellData[Int(c.parent)] : c
            if part.colorKind != -2 { slot = Int(part.colorSlot) }
        }
        let filtered = breakdown(of: group, colorSlot: slot)
        return filtered.fileCount > 0 ? filtered : breakdown(of: group)
    }
}
