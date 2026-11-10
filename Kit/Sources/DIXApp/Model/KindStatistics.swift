//
//  KindStatistics.swift
//  DIXApp
//
//  The kinds drawer's table: per file kind, the number of files and their
//  total size. Kinds are grouped by name, as the original's FileKindStatistic
//  and its colors were. Files count, plus packages when package contents are
//  hidden (they are then one cell in the treemap), exactly what KindColors
//  ranks.
//
//  GPL v3
//

import DIXCore
import DIXTreemap
import Foundation

public struct KindStatistic: Equatable, Sendable {
    public var name: String
    /// indexes into `snapshot.kinds` sharing this name
    public var kinds: [Int]
    public var size: UInt64
    public var fileCount: Int
    /// the treemap color slot (0..<12 palette, 12 grey)
    public var colorSlot: Int
}

public struct KindStatistics: Sendable {
    /// largest first
    public let entries: [KindStatistic]
    public let byName: [String: Int]

    public init(model: TreemapModel) {
        let s = model.snapshot
        let kindCount = s.kinds.count
        var size = [UInt64](repeating: 0, count: kindCount)
        var count = [Int](repeating: 0, count: kindCount)
        let sizes = model.sizeMode == .allocated ? s.allocatedSize : s.logicalSize
        let showPackages = model.showPackageContents
        // walk down from the root, stopping at packages drawn as one cell
        s.flags.withUnsafeBufferPointer { flags in
            s.kindIndex.withUnsafeBufferPointer { kinds in
                sizes.withUnsafeBufferPointer { sz in
                    var stack: [Int] = [Snapshot.root]
                    while let node = stack.popLast() {
                        let f = flags[node]
                        let isLeaf = !f.contains(.directory) || (f.contains(.package) && !showPackages && node != Snapshot.root)
                        if isLeaf {
                            let k = Int(kinds[node])
                            guard k < kindCount else { continue }
                            size[k] &+= sz[node]
                            count[k] += 1
                        } else {
                            let first = Int(s.firstChild[node])
                            for c in first ..< first + Int(s.childCount[node]) { stack.append(c) }
                        }
                    }
                }
            }
        }
        var grouped: [String: KindStatistic] = [:]
        for k in 0 ..< kindCount where count[k] > 0 {
            let name = s.kinds[k].name
            grouped[name, default: KindStatistic(name: name, kinds: [], size: 0, fileCount: 0,
                                                 colorSlot: model.kindColors.slot(ofKind: k))].kinds.append(k)
            grouped[name]!.size &+= size[k]
            grouped[name]!.fileCount += count[k]
        }
        let entries = grouped.values.sorted {
            $0.size != $1.size ? $0.size > $1.size : $0.name.compare($1.name, options: .numeric) == .orderedAscending
        }
        self.entries = entries
        var byName: [String: Int] = [:]
        for (i, e) in entries.enumerated() { byName[e.name] = i }
        self.byName = byName
    }

    public func entry(named name: String) -> KindStatistic? {
        byName[name].map { entries[$0] }
    }
}
