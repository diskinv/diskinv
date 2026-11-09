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

extension TreemapLayout {
    /// The drawn cell under a backing-pixel position (origin top left), or nil outside.
    public func cellIndex(atPixelX x: Int, y: Int) -> Int? {
        guard !cellData.isEmpty else { return nil }
        var index = 0
        var c = cellData[0]
        guard x >= Int(c.x0), x < Int(c.x1), y >= Int(c.y0), y < Int(c.y1) else { return nil }
        while c.role == .container {
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
        case .merged: return .merged(mergedGroups[Int(c.group)])
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
