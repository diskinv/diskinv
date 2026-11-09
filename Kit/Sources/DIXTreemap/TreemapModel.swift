//
//  TreemapModel.swift
//  DIXTreemap
//
//  Per-snapshot, per-size-mode data the treemap needs, computed once and
//  reused by every layout (window resizes, zooming): the kind colors, the
//  children's display order, each folder's representative kind and, in
//  logical mode, how much of each folder is cloud placeholders.
//
//  GPL v3
//

import DIXCore
import Foundation

public final class TreemapModel: Sendable {
    public let snapshot: Snapshot
    public let sizeMode: SizeMode
    /// when false (the original's default), packages are drawn as one cell
    public let showPackageContents: Bool
    public let kindColors: KindColors

    /// logical mode: node indexes in display order (size descending, ties in
    /// snapshot order), stored at the children's positions: the children of n
    /// are childOrder[firstChild[n] ..< firstChild[n] + childCount[n]].
    /// Empty in allocated mode, where the snapshot's own order is the display order.
    let childOrder: [UInt32]
    /// per node: the kind a merged cell uses for it. A file's or package's own
    /// kind; for a folder, the kind holding most bytes among its children's
    /// representative kinds (recursively).
    let representativeKind: [UInt16]
    /// logical mode only: bytes of cloud placeholders in each subtree
    let cloudBytes: [UInt64]
    let sizes: [UInt64]
    /// per folder: bytes per color slot of its subtree (see `colorMix(of:)`),
    /// computed only for folders that get merged, then cached
    let mixCache = ColorMixCache()

    public init(snapshot: Snapshot, sizeMode: SizeMode = .allocated, showPackageContents: Bool = false) {
        self.snapshot = snapshot
        self.sizeMode = sizeMode
        self.showPackageContents = showPackageContents
        let kindColors = KindColors(snapshot: snapshot, sizeMode: sizeMode, showPackageContents: showPackageContents)
        self.kindColors = kindColors
        let sizes = sizeMode == .allocated ? snapshot.allocatedSize : snapshot.logicalSize
        self.sizes = sizes

        let n = snapshot.nodeCount
        // display order
        var order: [UInt32] = []
        if sizeMode == .logical {
            order = [UInt32](repeating: 0, count: n)
            for node in 0 ..< n {
                let range = TreemapModel.childRange(snapshot, node)
                if range.isEmpty { continue }
                var kids = Array(range.lowerBound ..< range.upperBound)
                kids.sort { a, b in
                    let sa = sizes[a], sb = sizes[b]
                    return sa != sb ? sa > sb : a < b
                }
                for (i, k) in kids.enumerated() { order[range.lowerBound + i] = UInt32(k) }
            }
        }
        self.childOrder = order

        // representative kinds and cloud bytes, bottom up (children come after parents)
        var rep = [UInt16](repeating: 0, count: n)
        var cloud = [UInt64](repeating: 0, count: sizeMode == .logical ? n : 0)
        var acc = [UInt64](repeating: 0, count: max(1, snapshot.kinds.count))
        var touched: [Int] = []
        for node in stride(from: n - 1, through: 0, by: -1) {
            let flags = snapshot.flags[node]
            let range = TreemapModel.childRange(snapshot, node)
            if sizeMode == .logical {
                if flags.contains(.cloudPlaceholder) && !flags.contains(.directory) {
                    cloud[node] = snapshot.logicalSize[node]
                }
                for c in range { cloud[node] &+= cloud[c] }
            }
            let isLeaf = !flags.contains(.directory) || range.isEmpty || (flags.contains(.package) && !showPackageContents)
            if isLeaf {
                rep[node] = snapshot.kindIndex[node]
                continue
            }
            if range.count == 1 {
                rep[node] = rep[range.lowerBound]
                continue
            }
            touched.removeAll(keepingCapacity: true)
            for c in range {
                let k = Int(rep[c])
                if k >= acc.count { continue }
                if acc[k] == 0 { touched.append(k) }
                acc[k] &+= max(sizes[c], 1)
            }
            let best = kindColors.dominantKind(touched, &acc, fallback: Int(snapshot.kindIndex[node]))
            rep[node] = UInt16(truncatingIfNeeded: best)
        }
        self.representativeKind = rep
        self.cloudBytes = cloud
    }

    /// the size shown for a node in this model's size mode
    @inlinable public func size(of node: NodeIndex) -> UInt64 {
        snapshot.size(of: node, mode: sizeMode)
    }

    /// the children of a node in display order (largest first)
    public func orderedChildren(of node: NodeIndex) -> [NodeIndex] {
        let range = TreemapModel.childRange(snapshot, node)
        if childOrder.isEmpty { return Array(range) }
        return range.map { Int(childOrder[$0]) }
    }

    /// whether a node is laid out as a container of cells (a folder; a package
    /// only when package contents are shown, or when it is the layout root)
    public func isContainer(_ node: NodeIndex, isLayoutRoot: Bool = false) -> Bool {
        let flags = snapshot.flags[node]
        guard flags.contains(.directory), snapshot.childCount[node] > 0 else { return false }
        return isLayoutRoot || showPackageContents || !flags.contains(.package)
    }

    /// child index range, clamped to the snapshot so a malformed one can't trap
    static func childRange(_ s: Snapshot, _ node: NodeIndex) -> Range<Int> {
        let first = Int(s.firstChild[node]), count = Int(s.childCount[node])
        let lo = min(max(first, 0), s.nodeCount)
        return lo ..< min(lo + count, s.nodeCount)
    }

    /// Bytes per color in a node's subtree, as `colorSlotCount` values: slot
    /// 0..<12 = the palette colors, 12 = grey. A file or a package drawn as one
    /// cell counts entirely in its own kind's color. Folders are walked once and
    /// cached; this runs only for folders that end up merged.
    public func colorMix(of node: NodeIndex) -> [UInt64] {
        var mix = [UInt64](repeating: 0, count: KindColors.colorSlotCount)
        addColorMix(of: node, into: &mix)
        return mix
    }

    func addColorMix(of node: NodeIndex, into mix: inout [UInt64]) {
        let s = snapshot
        guard isContainer(node) else {
            mix[kindColors.slot(ofKind: Int(s.kindIndex[node]))] &+= sizes[node]
            return
        }
        if let cached = mixCache.get(node) {
            for i in 0 ..< mix.count { mix[i] &+= cached[i] }
            return
        }
        var own = [UInt64](repeating: 0, count: KindColors.colorSlotCount)
        var stack: [Int] = [node]
        while let n = stack.popLast() {
            if n != node, let cached = mixCache.get(n) {
                for i in 0 ..< own.count { own[i] &+= cached[i] }
                continue
            }
            for c in TreemapModel.childRange(s, n) {
                if isContainer(c) {
                    stack.append(c)
                } else {
                    own[kindColors.slot(ofKind: Int(s.kindIndex[c]))] &+= sizes[c]
                }
            }
        }
        mixCache.set(node, own)
        for i in 0 ..< mix.count { mix[i] &+= own[i] }
    }

    @inline(__always) func child(_ position: Int) -> Int {
        childOrder.isEmpty ? position : Int(childOrder[position])
    }

    /// Lays out the treemap of `root` (the zoomed folder; node 0 for the whole
    /// snapshot) into `pixelWidth` x `pixelHeight` backing pixels. `scale` is the
    /// backing scale factor (2 on Retina); point-based thresholds use it.
    public func layout(root: NodeIndex = Snapshot.root, pixelWidth: Int, pixelHeight: Int,
                       scale: Double = 1, options: TreemapOptions = TreemapOptions()) -> TreemapLayout {
        TreemapLayout(model: self, root: root, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                      scale: scale, options: options)
    }
}

/// A small thread-safe cache of folder color mixes (layouts may run on any thread).
final class ColorMixCache: @unchecked Sendable {
    private let lock = NSLock()
    private var mixes: [Int32: [UInt64]] = [:]

    func get(_ node: Int) -> [UInt64]? {
        lock.lock(); defer { lock.unlock() }
        return mixes[Int32(truncatingIfNeeded: node)]
    }

    func set(_ node: Int, _ mix: [UInt64]) {
        lock.lock(); defer { lock.unlock() }
        mixes[Int32(truncatingIfNeeded: node)] = mix
    }
}
