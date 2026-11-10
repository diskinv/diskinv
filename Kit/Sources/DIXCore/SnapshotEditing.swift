//
//  SnapshotEditing.swift
//  DIXCore
//
//  Changing a snapshot without rescanning the whole tree: dropping subtrees
//  (after Move to Trash), and replacing one folder's subtree with a fresh
//  scan of that folder.
//
//  Both produce a new Snapshot that passes validate() and describes the same
//  tree a fresh scan would (same entries, sizes, flags, kinds, child order,
//  hard-link keepers), and an index map from old nodes to new ones.
//
//  How (all O(nodes) memory traffic, but no per-node work beyond copying):
//  1. mark the removed nodes (whole subtrees)
//  2. compact: surviving nodes keep their relative order, so each node's
//     surviving children stay contiguous; most arrays are copied as whole
//     runs, only parent/firstChild/childCount are remapped one by one
//  3. a replacement subtree is appended after the survivors (its children
//     come after their parents, so the layout rule holds)
//  4. size deltas go up each changed node's ancestor chain; hard-link groups
//     that lost or gained a member elect their keeper again (smallest path,
//     as the scanner does)
//  5. only the sibling ranges whose sizes changed are sorted again
//
//  The result is not necessarily in breadth-first order (sorting a range moves
//  nodes without moving their subtrees), which the Snapshot contract does not
//  require: children are contiguous, after their parent, and sorted.
//
//  Name bytes of removed nodes are left in place (the new snapshot shares the
//  old name buffer); the buffer is compacted once dead bytes outweigh live
//  ones. The kind table is never shrunk, so kind indexes stay stable across
//  edits; a replacement adds the subtree's new kinds at the end.
//
//  GPL v3
//

import Foundation

extension Snapshot {
    /// A new snapshot without the subtrees of `nodes` (e.g. after Move to Trash).
    /// Ancestors' allocated/logical sizes are reduced and their children re-sorted.
    /// indexMap[old] = new index, or UInt32.max if removed.
    ///
    /// Nodes may be nested or repeated. The root cannot be removed and is
    /// ignored. If a removed file was the keeper of a hard-linked inode whose
    /// other links remain, the remaining link with the smallest path takes
    /// over its allocated size (the space is not freed until every link is gone).
    public func removing(_ nodes: [NodeIndex]) -> (snapshot: Snapshot, indexMap: [UInt32]) {
        var edit = SnapshotEdit(self)
        for node in nodes {
            precondition(node >= 0 && node < nodeCount, "removing: node \(node) out of range")
            if node != Snapshot.root { edit.remove(node) }
        }
        return edit.finish(replacing: nil)
    }

    /// A new snapshot in which the folder `node` is replaced by `subtree`
    /// (a fresh scan of that same folder; subtree's root becomes `node`).
    /// Ancestors' sizes adjusted and re-sorted. indexMap maps old indexes of nodes
    /// outside the replaced subtree to their new indexes (UInt32.max inside it).
    ///
    /// `node` keeps its name, and its package / mount point / cloud flags and
    /// kind as its parent's listing saw them (a scan's root cannot see its own
    /// Finder bundle bit); `.unreadable` comes from the fresh scan. Hard-link
    /// groups that span the boundary elect their keeper again, with the fresh
    /// scan's allocated size. The subtree's rootPath, scan date and volume
    /// are not used.
    public func replacingSubtree(at node: NodeIndex, with subtree: Snapshot) -> (snapshot: Snapshot, indexMap: [UInt32]) {
        precondition(node >= 0 && node < nodeCount && isDirectory(node), "replacingSubtree: \(node) is not a folder")
        precondition(subtree.nodeCount > 0 && subtree.isDirectory(Snapshot.root), "replacingSubtree: the subtree's root is not a folder")
        var edit = SnapshotEdit(self)
        for child in children(of: node) { edit.remove(child) }
        return edit.finish(replacing: (node, subtree))
    }
}

private struct LinkKey: Hashable {
    var device: UInt32
    var fileID: UInt64
}

private struct SnapshotEdit {
    let old: Snapshot
    /// old index -> new index; while marking, UInt32.max = removed
    var map: [UInt32]
    /// removed nodes whose parent may survive (filtered in finish)
    var removedRoots: [Int] = []
    var removedCount = 0

    init(_ snapshot: Snapshot) {
        old = snapshot
        map = [UInt32](repeating: 0, count: snapshot.nodeCount)
    }

    mutating func remove(_ node: Int) {
        guard map[node] != .max else { return }     // inside an earlier selection
        removedRoots.append(node)
        var stack = [node]
        while let current = stack.popLast() {
            // an earlier selection below this one: its subtree is already marked
            guard map[current] != .max else { continue }
            map[current] = .max
            removedCount += 1
            let first = Int(old.firstChild[current]), count = Int(old.childCount[current])
            if count > 0 { stack.append(contentsOf: first ..< first + count) }
        }
    }

    // MARK: the new snapshot, being built

    private var parent: [UInt32] = []
    private var firstChild: [UInt32] = []
    private var childCount: [UInt32] = []
    private var allocated: [UInt64] = []
    private var logical: [UInt64] = []
    private var nameOffset: [UInt32] = []
    private var nameLength: [UInt16] = []
    private var kindIndex: [UInt16] = []
    private var flags: [NodeFlags] = []
    private var nameBytes: [UInt8] = []
    private var kinds: [FileKind] = []
    /// runs of surviving old nodes: old[src ..< src+count] -> new[dst ..< dst+count]
    private var runs: [(src: Int, dst: Int, count: Int)] = []
    /// first new index of the appended subtree (subtree node k is at base + k - 1)
    private var base = 0
    /// subtree node -> new index (only for a replacement)
    private var subtreeMap: [UInt32] = []
    /// nodes whose children must be sorted again
    private var unsortedParents = Set<UInt32>()

    mutating func finish(replacing replacement: (node: Int, subtree: Snapshot)?) -> (snapshot: Snapshot, indexMap: [UInt32]) {
        let n = old.nodeCount
        if removedCount == 0 && replacement == nil {
            return (old, Array(0 ..< UInt32(n)))
        }
        // removed roots whose parent survives: their sizes leave the ancestors
        let parentsOld = old.parent
        removedRoots = removedRoots.filter { map[Int(parentsOld[$0])] != .max }

        let subtree = replacement?.subtree
        let total = n - removedCount + (subtree.map { $0.nodeCount - 1 } ?? 0)
        precondition(total <= Int(UInt32.max) && n + total <= Int(UInt32.max), "snapshot too large")
        compact(capacity: total)
        kinds = old.kinds
        nameBytes = old.nameBytes

        // sizes of removed subtrees leave their ancestors, summed per parent first
        var lost: [UInt32: (allocated: UInt64, logical: UInt64)] = [:]
        for root in removedRoots {
            let p = map[Int(old.parent[root])]
            let entry = lost[p] ?? (0, 0)
            lost[p] = (entry.allocated &+ old.allocatedSize[root], entry.logical &+ old.logicalSize[root])
        }
        if let (node, subtree) = replacement {
            append(subtree, at: Int(map[node]), oldNode: node)
            // the replaced node's own subtree is gone: it gets the fresh sizes instead
            let p = map[node]
            lost[p] = nil
            let delta = (allocated: subtree.allocatedSize[0] &- old.allocatedSize[node],
                         logical: subtree.logicalSize[0] &- old.logicalSize[node])
            if p != 0 {
                propagate(from: Int(parent[Int(p)]), allocated: delta.allocated, logical: delta.logical)
                if delta.allocated != 0 { unsortedParents.insert(parent[Int(p)]) }
            }
        }
        for (p, sizes) in lost {
            propagate(from: Int(p), allocated: 0 &- sizes.allocated, logical: 0 &- sizes.logical)
        }
        reelectHardLinkKeepers(subtree: subtree)
        sortChangedRanges()
        let links = finalHardLinks(subtree: subtree)
        compactNamesIfWasteful()

        var result = old
        result.parent = parent
        result.firstChild = firstChild
        result.childCount = childCount
        result.allocatedSize = allocated
        result.logicalSize = logical
        result.nameOffset = nameOffset
        result.nameLength = nameLength
        result.kindIndex = kindIndex
        result.flags = flags
        result.nameBytes = nameBytes
        result.kinds = kinds
        result.hardLinks = links
        return (result, map)
    }

    // MARK: 2. compaction

    /// `capacity`: room for the subtree appended afterwards, so appending
    /// does not reallocate the arrays
    private mutating func compact(capacity: Int) {
        let n = old.nodeCount
        var next = 0
        map.withUnsafeMutableBufferPointer { m in
            var i = 0
            while i < n {
                if m[i] == .max { i += 1; continue }
                let start = i, dst = next
                while i < n && m[i] != .max {
                    m[i] = UInt32(truncatingIfNeeded: next)
                    i += 1
                    next += 1
                }
                runs.append((start, dst, i - start))
            }
        }
        base = next
        let count = next
        let runs = self.runs
        let map = self.map

        func copyRuns<T>(_ source: [T]) -> [T] {
            [T](unsafeUninitializedCapacity: capacity) { buffer, initialized in
                source.withUnsafeBufferPointer { src in
                    for run in runs {
                        UnsafeMutableRawPointer(buffer.baseAddress! + run.dst)
                            .copyMemory(from: src.baseAddress! + run.src, byteCount: run.count * MemoryLayout<T>.stride)
                    }
                }
                initialized = count
            }
        }
        allocated = copyRuns(old.allocatedSize)
        logical = copyRuns(old.logicalSize)
        nameOffset = copyRuns(old.nameOffset)
        nameLength = copyRuns(old.nameLength)
        kindIndex = copyRuns(old.kindIndex)
        flags = copyRuns(old.flags)

        parent = [UInt32](unsafeUninitializedCapacity: capacity) { buffer, initialized in
            map.withUnsafeBufferPointer { m in
                old.parent.withUnsafeBufferPointer { p in
                    for run in runs {
                        for k in 0 ..< run.count { buffer[run.dst + k] = m[Int(p[run.src + k])] }
                    }
                }
            }
            initialized = count
        }
        var newFirst = [UInt32](), newCount = [UInt32]()
        newFirst.reserveCapacity(capacity)
        newCount.reserveCapacity(capacity)
        newFirst.append(contentsOf: repeatElement(0, count: count))
        newCount.append(contentsOf: repeatElement(0, count: count))
        map.withUnsafeBufferPointer { m in
            old.firstChild.withUnsafeBufferPointer { f in
                old.childCount.withUnsafeBufferPointer { c in
                    newFirst.withUnsafeMutableBufferPointer { nf in
                        newCount.withUnsafeMutableBufferPointer { nc in
                            for run in runs {
                                for k in 0 ..< run.count {
                                    let i = run.src + k
                                    let cnt = Int(c[i])
                                    guard cnt > 0 else { continue }
                                    let first = Int(f[i])
                                    let a = m[first], b = m[first + cnt - 1]
                                    if a != .max && b != .max && Int(b - a) == cnt - 1 {
                                        // no child removed (the map is monotone)
                                        nf[run.dst + k] = a
                                        nc[run.dst + k] = UInt32(cnt)
                                    } else {
                                        var survivors = 0, firstSurvivor = UInt32(0)
                                        for child in first ..< first + cnt where m[child] != .max {
                                            if survivors == 0 { firstSurvivor = m[child] }
                                            survivors += 1
                                        }
                                        nf[run.dst + k] = survivors > 0 ? firstSurvivor : 0
                                        nc[run.dst + k] = UInt32(survivors)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        firstChild = newFirst
        childCount = newCount
    }

    // MARK: 3. appending a replacement subtree

    private mutating func append(_ subtree: Snapshot, at node: Int, oldNode: Int) {
        let m = subtree.nodeCount
        let added = m - 1
        let base = self.base
        // kinds: reuse equal ones, add the others at the end
        var kindIndexOf: [FileKind: UInt16] = [:]
        for (i, kind) in kinds.enumerated() where kindIndexOf[kind] == nil { kindIndexOf[kind] = UInt16(i) }
        let kindRemap: [UInt16] = subtree.kinds.map { kind in
            if let i = kindIndexOf[kind] { return i }
            guard kinds.count <= Int(UInt16.max) else { return 0 }     // table full (65536 kinds)
            kinds.append(kind)
            kindIndexOf[kind] = UInt16(kinds.count - 1)
            return UInt16(kinds.count - 1)
        }
        let nameBase = UInt32(nameBytes.count)
        precondition(nameBytes.count + subtree.nameBytes.count <= Int(UInt32.max), "name bytes overflow")
        nameBytes.append(contentsOf: subtree.nameBytes)

        let nodeIndex = UInt32(node)
        func shifted(_ k: UInt32) -> UInt32 { UInt32(base) + k - 1 }
        for k in 1 ..< max(1, m) {
            let p = subtree.parent[k]
            parent.append(p == 0 ? nodeIndex : shifted(p))
            let c = subtree.childCount[k]
            firstChild.append(c > 0 ? shifted(subtree.firstChild[k]) : 0)
            childCount.append(c)
            nameOffset.append(nameBase + subtree.nameOffset[k])
            kindIndex.append(kindRemap[Int(subtree.kindIndex[k])])
        }
        if added > 0 {
            allocated.append(contentsOf: subtree.allocatedSize[1...])
            logical.append(contentsOf: subtree.logicalSize[1...])
            nameLength.append(contentsOf: subtree.nameLength[1...])
            flags.append(contentsOf: subtree.flags[1...])
        }
        subtreeMap = [UInt32](unsafeUninitializedCapacity: m) { buffer, initialized in
            buffer[0] = nodeIndex
            for k in 1 ..< max(1, m) { buffer[k] = UInt32(base + k - 1) }
            initialized = m
        }

        // the node itself
        let rootChildren = subtree.childCount[0]
        firstChild[node] = rootChildren > 0 ? shifted(subtree.firstChild[0]) : 0
        childCount[node] = rootChildren
        allocated[node] = subtree.allocatedSize[0]
        logical[node] = subtree.logicalSize[0]
        let was = old.flags[oldNode], fresh = subtree.flags[0]
        var merged = NodeFlags.directory
        merged.formUnion(was.intersection([.package, .mountPoint, .cloudPlaceholder]))
        merged.formUnion(fresh.intersection([.package, .unreadable]))
        if rootChildren > 0 { merged.subtract([.mountPoint, .cloudPlaceholder]) }     // it was descended now
        flags[node] = merged
        if was.contains(.package) {
            kindIndex[node] = old.kindIndex[oldNode]
        } else {
            kindIndex[node] = merged.contains(.package) ? kindRemap[Int(subtree.kindIndex[0])] : 0
        }
    }

    // MARK: 4. sizes and hard links

    /// adds the (wrapping) deltas to `start` and all its ancestors, and notes
    /// which sibling ranges need sorting again
    private mutating func propagate(from start: Int, allocated dA: UInt64, logical dL: UInt64) {
        guard dA != 0 || dL != 0 else { return }
        var node = start
        while true {
            allocated[node] &+= dA
            logical[node] &+= dL
            if node == 0 { break }
            let p = parent[node]
            if dA != 0 { unsortedParents.insert(p) }
            node = Int(p)
        }
    }

    /// path of a new node relative to the root, as bytes (the root's own name
    /// is common to all paths, so it is left out of comparisons)
    private func relativePath(_ node: Int) -> [UInt8] {
        var components: [Int] = []
        var current = node
        while current != 0 {
            components.append(current)
            current = Int(parent[current])
        }
        var bytes: [UInt8] = []
        for c in components.reversed() {
            if !bytes.isEmpty { bytes.append(UInt8(ascii: "/")) }
            let start = Int(nameOffset[c])
            bytes.append(contentsOf: nameBytes[start ..< start + Int(nameLength[c])])
        }
        return bytes
    }

    /// For each hard-linked inode that lost a link (removed) or gained one
    /// (from the subtree), the remaining link with the smallest path keeps the
    /// size and the others become duplicates, exactly as a scan decides it.
    private mutating func reelectHardLinkKeepers(subtree: Snapshot?) {
        var touched = Set<LinkKey>()
        for link in old.hardLinks where map[Int(link.node)] == .max {
            touched.insert(LinkKey(device: link.device, fileID: link.fileID))
        }
        for link in subtree?.hardLinks ?? [] {
            touched.insert(LinkKey(device: link.device, fileID: link.fileID))
        }
        guard !touched.isEmpty else { return }

        struct Group { var members: [Int] = []; var oldSize: UInt64?; var freshSize: UInt64? }
        var groups: [LinkKey: Group] = [:]
        for link in old.hardLinks {
            let key = LinkKey(device: link.device, fileID: link.fileID)
            guard touched.contains(key) else { continue }
            let node = Int(link.node)
            if !old.flags[node].contains(.hardLinkDuplicate) { groups[key, default: Group()].oldSize = old.allocatedSize[node] }
            if map[node] != .max { groups[key, default: Group()].members.append(Int(map[node])) }
        }
        if let subtree {
            for link in subtree.hardLinks {
                let key = LinkKey(device: link.device, fileID: link.fileID)
                let node = Int(link.node)
                if !subtree.flags[node].contains(.hardLinkDuplicate) { groups[key, default: Group()].freshSize = subtree.allocatedSize[node] }
                groups[key, default: Group()].members.append(Int(subtreeMap[node]))
            }
        }
        for group in groups.values {
            // the fresh scan's size is newer; a group with no keeper (cannot
            // happen in a valid snapshot) is left alone
            guard !group.members.isEmpty, let size = group.freshSize ?? group.oldSize else { continue }
            let paths = group.members.map { relativePath($0) }
            var keeper = 0
            for i in 1 ..< paths.count where paths[i].lexicographicallyPrecedes(paths[keeper]) { keeper = i }
            for (i, member) in group.members.enumerated() {
                let target: UInt64 = i == keeper ? size : 0
                if i == keeper { flags[member].remove(.hardLinkDuplicate) } else { flags[member].insert(.hardLinkDuplicate) }
                if allocated[member] != target {
                    propagate(from: member, allocated: target &- allocated[member], logical: 0)
                }
            }
        }
    }

    // MARK: 5. order

    /// does a come strictly before b among siblings (allocated descending,
    /// then name bytes ascending, as the scanner sorts)?
    private func precedes(_ a: Int, _ b: Int) -> Bool {
        if allocated[a] != allocated[b] { return allocated[a] > allocated[b] }
        let sa = Int(nameOffset[a]), sb = Int(nameOffset[b])
        return nameBytes.withUnsafeBufferPointer { names in
            let na = UnsafeBufferPointer(rebasing: names[sa ..< sa + Int(nameLength[a])])
            let nb = UnsafeBufferPointer(rebasing: names[sb ..< sb + Int(nameLength[b])])
            return na.lexicographicallyPrecedes(nb)
        }
    }

    private mutating func sortChangedRanges() {
        // ranges are fixed slot intervals: collect them all before moving anything
        let ranges = unsortedParents.map { (Int(firstChild[Int($0)]), Int(childCount[Int($0)])) }
        for (first, count) in ranges where count > 1 {
            var sorted = true
            for i in first + 1 ..< first + count where precedes(i, i - 1) { sorted = false; break }
            if sorted { continue }
            let order = (first ..< first + count).sorted { precedes($0, $1) }
            permute(first: first, order: order)
        }
    }

    /// moves the nodes of slots `order` into slots first ..< first + order.count
    private mutating func permute(first: Int, order: [Int]) {
        func apply<T>(_ array: inout [T]) {
            let values = order.map { array[$0] }
            for (k, v) in values.enumerated() { array[first + k] = v }
        }
        // `parent` is the same for the whole range
        apply(&firstChild); apply(&childCount); apply(&allocated); apply(&logical)
        apply(&nameOffset); apply(&nameLength); apply(&kindIndex); apply(&flags)
        for (k, from) in order.enumerated() where from != first + k {
            let to = first + k
            let c = Int(childCount[to])
            if c > 0 {
                let f = Int(firstChild[to])
                for child in f ..< f + c { parent[child] = UInt32(to) }
            }
            // whoever started in slot `from` now lives in `to`
            if from >= base {
                subtreeMap[from - base + 1] = UInt32(to)
            } else {
                map[oldIndex(ofSlot: from)] = UInt32(to)
            }
        }
    }

    /// the old node first placed in new slot `slot` (< base)
    private func oldIndex(ofSlot slot: Int) -> Int {
        var low = 0, high = runs.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if runs[mid].dst <= slot { low = mid } else { high = mid - 1 }
        }
        return runs[low].src + (slot - runs[low].dst)
    }

    private func finalHardLinks(subtree: Snapshot?) -> [HardLink] {
        var links: [HardLink] = []
        for link in old.hardLinks where map[Int(link.node)] != .max {
            links.append(HardLink(node: map[Int(link.node)], device: link.device, fileID: link.fileID))
        }
        for link in subtree?.hardLinks ?? [] {
            links.append(HardLink(node: subtreeMap[Int(link.node)], device: link.device, fileID: link.fileID))
        }
        links.sort { $0.node < $1.node }
        return links
    }

    // MARK: names

    private mutating func compactNamesIfWasteful() {
        var live = 0
        nameLength.withUnsafeBufferPointer { for l in $0 { live &+= Int(l) } }
        guard nameBytes.count > 2 * live + 4096 else { return }
        var compacted: [UInt8] = []
        compacted.reserveCapacity(live)
        let oldNames = nameBytes
        oldNames.withUnsafeBufferPointer { names in
            for node in 0 ..< nameOffset.count {
                let start = Int(nameOffset[node])
                nameOffset[node] = UInt32(compacted.count)
                compacted.append(contentsOf: UnsafeBufferPointer(rebasing: names[start ..< start + Int(nameLength[node])]))
            }
        }
        nameBytes = compacted
    }
}
