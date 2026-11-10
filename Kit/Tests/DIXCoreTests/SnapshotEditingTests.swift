//
//  SnapshotEditingTests.swift
//  DIXCoreTests
//
//  Snapshot.removing / replacingSubtree against a naive reference: rebuild
//  the tree from scratch (sizes summed again, children sorted again) and
//  compare the two trees row by row in depth-first order.
//
//  GPL v3
//

import Foundation
import Testing
@testable import DIXCore

/// One node as a tree comparison sees it: everything but its index.
struct TreeRow: Hashable, CustomStringConvertible {
    var path: [UInt8]
    var allocated: UInt64
    var logical: UInt64
    var flags: UInt16
    var kind: FileKind
    var childCount: Int
    var description: String {
        "\(String(decoding: path, as: UTF8.self)) a=\(allocated) l=\(logical) f=\(flags) k=\(kind.name) c=\(childCount)"
    }
}

/// depth-first rows of a snapshot, children in snapshot order, paths relative to the root
func treeRows(_ s: Snapshot) -> [TreeRow] {
    var rows: [TreeRow] = []
    var stack: [(Int, [UInt8])] = [(0, [])]
    while let (node, path) = stack.popLast() {
        rows.append(TreeRow(path: path, allocated: s.allocatedSize[node], logical: s.logicalSize[node],
                            flags: s.flags[node].rawValue, kind: s.kind(of: node), childCount: Int(s.childCount[node])))
        for child in s.children(of: node).reversed() {
            let start = Int(s.nameOffset[child])
            let name = Array(s.nameBytes[start ..< start + Int(s.nameLength[child])])
            stack.append((child, path.isEmpty ? name : path + [UInt8(ascii: "/")] + name))
        }
    }
    return rows
}

/// A mutable tree, rebuilt into a Snapshot the simple way (BFS, sorted, sums).
struct ModelTree {
    struct Node { var name: [UInt8]; var allocated: UInt64; var logical: UInt64; var flags: NodeFlags; var kind: FileKind; var children: [Int] }
    var nodes: [Node] = []

    init(_ s: Snapshot) {
        nodes = (0 ..< s.nodeCount).map { i in
            let start = Int(s.nameOffset[i])
            return Node(name: Array(s.nameBytes[start ..< start + Int(s.nameLength[i])]), allocated: s.allocatedSize[i],
                        logical: s.logicalSize[i], flags: s.flags[i], kind: s.kind(of: i), children: Array(s.children(of: i)))
        }
    }

    /// splices `other`'s root children in as the children of `node`
    mutating func replaceChildren(of node: Int, with other: ModelTree) {
        let offset = nodes.count - 1
        for (i, n) in other.nodes.enumerated() where i > 0 {
            var copy = n
            copy.children = n.children.map { $0 + offset }
            nodes.append(copy)
        }
        nodes[node].children = other.nodes[0].children.map { $0 + offset }
        nodes[node].flags.remove(.unreadable)
        nodes[node].flags.formUnion(other.nodes[0].flags.intersection(.unreadable))
    }

    func rows() -> [TreeRow] {
        var sizes = [(UInt64, UInt64)](repeating: (0, 0), count: nodes.count)
        func total(_ i: Int) -> (UInt64, UInt64) {
            // iterative post-order: trees can be deep
            var order: [Int] = [], stack = [i]
            while let n = stack.popLast() { order.append(n); stack.append(contentsOf: nodes[n].children) }
            for n in order.reversed() {
                if nodes[n].flags.contains(.directory) {
                    sizes[n] = nodes[n].children.reduce((0, 0)) { ($0.0 + sizes[$1].0, $0.1 + sizes[$1].1) }
                } else {
                    sizes[n] = (nodes[n].allocated, nodes[n].logical)
                }
            }
            return sizes[i]
        }
        _ = total(0)
        var rows: [TreeRow] = []
        var stack: [(Int, [UInt8])] = [(0, [])]
        while let (node, path) = stack.popLast() {
            let n = nodes[node]
            rows.append(TreeRow(path: path, allocated: sizes[node].0, logical: sizes[node].1, flags: n.flags.rawValue,
                                kind: n.kind, childCount: n.children.count))
            let sorted = n.children.sorted { a, b in
                sizes[a].0 != sizes[b].0 ? sizes[a].0 > sizes[b].0 : nodes[a].name.lexicographicallyPrecedes(nodes[b].name)
            }
            for child in sorted.reversed() {
                stack.append((child, path.isEmpty ? nodes[child].name : path + [UInt8(ascii: "/")] + nodes[child].name))
            }
        }
        return rows
    }
}

/// the first difference between two row lists, or nil
func firstDifference(_ a: [TreeRow], _ b: [TreeRow]) -> String? {
    for (i, (x, y)) in zip(a, b).enumerated() where x != y { return "row \(i): \(x) vs \(y)" }
    return a.count == b.count ? nil : "row counts \(a.count) vs \(b.count)"
}

private func checkIndexMap(old: Snapshot, new: Snapshot, map: [UInt32], removed: Set<Int>) {
    #expect(map.count == old.nodeCount)
    var hits = Set<UInt32>()
    for i in 0 ..< old.nodeCount {
        if removed.contains(i) {
            #expect(map[i] == .max, "node \(i) should be removed")
            continue
        }
        let j = Int(map[i])
        #expect(j < new.nodeCount)
        #expect(hits.insert(map[i]).inserted, "two old nodes map to \(j)")
        #expect(new.path(of: j) == old.path(of: i))
        #expect(new.flags[j] == old.flags[i] || i == 0 || old.isDirectory(i))
        if !old.isDirectory(i) {
            #expect(new.allocatedSize[j] == old.allocatedSize[i] && new.logicalSize[j] == old.logicalSize[i])
        }
    }
}

private func subtreeNodes(_ s: Snapshot, _ roots: [Int]) -> Set<Int> {
    var out = Set<Int>(), stack = roots
    while let n = stack.popLast() {
        if out.insert(n).inserted { stack.append(contentsOf: s.children(of: n)) }
    }
    return out
}

@Suite struct SnapshotEditingTests {
    @Test func randomRemovalsMatchTheReference() throws {
        var rng = SplitMix(state: 0xED17)
        for seed in 0 ..< 40 as Range<UInt64> {
            var s = randomSnapshot(count: Int.random(in: 2 ... 600, using: &rng), seed: 1000 + seed)
            // a few removals in a row: later ones edit an edited (non-BFS) snapshot
            for _ in 0 ..< 4 where s.nodeCount > 1 {
                var picks: [Int] = []
                for _ in 0 ..< Int.random(in: 1 ... 6, using: &rng) {
                    let node = Int.random(in: 1 ..< s.nodeCount, using: &rng)
                    picks.append(node)
                    // sometimes also an ancestor, a descendant, or the same node again
                    switch Int.random(in: 0 ..< 4, using: &rng) {
                    case 0: picks.append(Int(s.parent[node]))
                    case 1: if s.childCount[node] > 0 { picks.append(Int(s.firstChild[node])) }
                    case 2: picks.append(node)
                    default: break
                    }
                }
                let removed = subtreeNodes(s, picks.filter { $0 != 0 })
                var model = ModelTree(s)
                for i in 0 ..< s.nodeCount { model.nodes[i].children.removeAll { removed.contains($0) } }
                let (edited, map) = s.removing(picks)
                #expect(edited.validate() == nil, "seed \(seed): \(edited.validate() ?? "")")
                #expect(edited.nodeCount == s.nodeCount - removed.count)
                if let diff = firstDifference(treeRows(edited), model.rows()) { Issue.record("seed \(seed): \(diff)") }
                checkIndexMap(old: s, new: edited, map: map, removed: removed)
                s = edited
            }
        }
    }

    @Test func removingAllOfTheRootsChildren() throws {
        let s = randomSnapshot(count: 300, seed: 77)
        let (edited, map) = s.removing(Array(s.children(of: 0)))
        #expect(edited.validate() == nil)
        #expect(edited.nodeCount == 1)
        #expect(edited.childCount[0] == 0 && edited.allocatedSize[0] == 0 && edited.logicalSize[0] == 0)
        #expect(map[0] == 0)
        #expect(map.dropFirst().allSatisfy { $0 == .max })
        // and some of them, plus the root (ignored), plus repeats
        let some = Array(s.children(of: 0).prefix(3))
        let (partial, _) = s.removing(some + some + [0])
        #expect(partial.validate() == nil)
        let expected = s.allocatedSize[0] - some.reduce(0) { $0 + s.allocatedSize[$1] }
        #expect(partial.allocatedSize[0] == expected)
    }

    @Test func nestedSelectionsAndANodeWithItsAncestor() throws {
        let s = randomSnapshot(count: 2000, seed: 78)
        // the deepest node, all of its ancestors, in every order
        let deepest = (0 ..< s.nodeCount).max { a, b in depth(s, a) < depth(s, b) }!
        var chain: [Int] = []
        var n = deepest
        while n != 0 { chain.append(n); n = Int(s.parent[n]) }
        let top = chain.last!
        let expected = s.removing([top])
        for selection in [chain, chain.reversed(), [deepest, top], [top, deepest]] {
            let (edited, map) = s.removing(selection)
            #expect(edited.validate() == nil)
            #expect(treeRows(edited) == treeRows(expected.snapshot))
            #expect(map == expected.indexMap)
        }
    }

    @Test func nothingToRemoveIsTheSameSnapshot() {
        let s = randomSnapshot(count: 50, seed: 79)
        let (same, map) = s.removing([0])
        #expect(same.parent == s.parent && same.allocatedSize == s.allocatedSize)
        #expect(map == Array(0 ..< 50))
        let (empty, _) = s.removing([])
        #expect(empty.nodeCount == 50)
    }

    @Test func randomReplacementsMatchTheReference() throws {
        var rng = SplitMix(state: 0x5EB7)
        for seed in 0 ..< 40 as Range<UInt64> {
            var s = randomSnapshot(count: Int.random(in: 2 ... 500, using: &rng), seed: 2000 + seed)
            for round in 0 ..< 4 {
                let directories = (0 ..< s.nodeCount).filter { s.isDirectory($0) }
                let node = directories[Int.random(in: 0 ..< directories.count, using: &rng)]
                var subtree = randomSnapshot(count: Int.random(in: 1 ... 200, using: &rng), seed: 3000 + seed * 10 + UInt64(round))
                // a kind the snapshot does not have yet
                subtree.kinds.append(FileKind(identifier: "test.new-\(round)", name: "New \(round)"))
                for i in 0 ..< subtree.nodeCount where !subtree.isDirectory(i) && i % 3 == 0 {
                    subtree.kindIndex[i] = UInt16(subtree.kinds.count - 1)
                }
                if Bool.random(using: &rng) { subtree.flags[0].insert(.unreadable) }
                var model = ModelTree(s)
                model.replaceChildren(of: node, with: ModelTree(subtree))
                let (edited, map) = s.replacingSubtree(at: node, with: subtree)
                #expect(edited.validate() == nil, "seed \(seed): \(edited.validate() ?? "")")
                if let diff = firstDifference(treeRows(edited), model.rows()) { Issue.record("seed \(seed) round \(round): \(diff)") }
                let inside = subtreeNodes(s, Array(s.children(of: node)))
                checkIndexMap(old: s, new: edited, map: map, removed: inside)
                #expect(edited.name(of: Int(map[node])) == s.name(of: node))
                s = edited
            }
        }
    }

    @Test func replacingTheRoot() throws {
        let s = randomSnapshot(count: 400, seed: 80)
        let subtree = randomSnapshot(count: 90, seed: 81)
        let (edited, map) = s.replacingSubtree(at: 0, with: subtree)
        #expect(edited.validate() == nil)
        #expect(edited.nodeCount == 90)
        #expect(edited.rootPath == s.rootPath)
        #expect(map[0] == 0 && map.dropFirst().allSatisfy { $0 == .max })
        var model = ModelTree(s)
        model.replaceChildren(of: 0, with: ModelTree(subtree))
        #expect(firstDifference(treeRows(edited), model.rows()) == nil)
    }

    /// root { a/ { x }, b/ { y }, z } where a/x, b/y and z are one inode
    private func linkedSnapshot() -> Snapshot {
        // BFS: 0 root, 1 a (size 8), 2 b (0), 3 z (0), 4 a/x (8), 5 b/y (0)
        let names = Array("rootabzxy".utf8)
        let dup: NodeFlags = .hardLinkDuplicate
        return Snapshot(
            rootPath: "/r", scanDate: Date(timeIntervalSince1970: 0), volume: nil,
            parent: [0, 0, 0, 0, 1, 2], firstChild: [1, 4, 5, 0, 0, 0], childCount: [3, 1, 1, 0, 0, 0],
            allocatedSize: [8, 8, 0, 0, 8, 0], logicalSize: [30, 10, 10, 10, 10, 10],
            nameOffset: [0, 4, 5, 6, 7, 8], nameLength: [4, 1, 1, 1, 1, 1],
            kindIndex: [0, 0, 0, 1, 1, 1], flags: [.directory, .directory, .directory, dup, [], dup],
            nameBytes: names, kinds: [FileKind(identifier: "public.folder", name: "Folder"), FileKind(identifier: "", name: "Document")],
            hardLinks: [HardLink(node: 3, device: 1, fileID: 42), HardLink(node: 4, device: 1, fileID: 42),
                        HardLink(node: 5, device: 1, fileID: 42)])
    }

    @Test func removingTheKeeperOfAHardLinkMovesItsSize() throws {
        let s = linkedSnapshot()
        #expect(s.validate() == nil)
        // remove a/x: b/y ("b/y" < "z") keeps the 8 bytes now
        let (edited, map) = s.removing([4])
        #expect(edited.validate() == nil)
        let y = Int(map[5]), b = Int(map[2])
        #expect(edited.allocatedSize[y] == 8 && !edited.flags[y].contains(.hardLinkDuplicate))
        #expect(edited.allocatedSize[b] == 8 && edited.allocatedSize[0] == 8)
        #expect(edited.flags[Int(map[3])].contains(.hardLinkDuplicate))
        #expect(edited.hardLinks.count == 2)
        // b (8) now sorts before a (0)
        #expect(edited.name(of: Int(edited.firstChild[0])) == "b")
        // then remove b too: z keeps it
        let (again, map2) = edited.removing([b])
        #expect(again.validate() == nil)
        let z = Int(map2[Int(map[3])])
        #expect(again.allocatedSize[z] == 8 && again.allocatedSize[0] == 8)
        #expect(again.hardLinks == [HardLink(node: UInt32(z), device: 1, fileID: 42)])
        // removing a duplicate changes nothing but the count
        let (noDup, _) = s.removing([3])
        #expect(noDup.validate() == nil && noDup.allocatedSize[0] == 8)
        // removing every link frees the space
        let (gone, _) = s.removing([1, 2, 3])
        #expect(gone.validate() == nil && gone.allocatedSize[0] == 0 && gone.hardLinks.isEmpty)
    }

    @Test func replacementElectsHardLinkKeepersAcrossTheBoundary() throws {
        let s = linkedSnapshot()
        // a fresh scan of b/ that sees y as its own keeper (the other links are outside it)
        let fresh = Snapshot(
            rootPath: "/r/b", scanDate: Date(timeIntervalSince1970: 0), volume: nil,
            parent: [0, 0], firstChild: [1, 0], childCount: [1, 0], allocatedSize: [8, 8], logicalSize: [10, 10],
            nameOffset: [0, 1], nameLength: [1, 1], kindIndex: [0, 1], flags: [.directory, []],
            nameBytes: Array("by".utf8), kinds: [FileKind(identifier: "public.folder", name: "Folder"), FileKind(identifier: "", name: "Document")],
            hardLinks: [HardLink(node: 1, device: 1, fileID: 42)])
        let (edited, map) = s.replacingSubtree(at: 2, with: fresh)
        #expect(edited.validate() == nil, "\(edited.validate() ?? "")")
        // a/x is still the smallest path: b/y goes back to being a duplicate
        #expect(edited.allocatedSize[0] == 8)
        #expect(edited.allocatedSize[Int(map[4])] == 8)
        #expect(edited.allocatedSize[Int(map[2])] == 0)
        #expect(edited.hardLinks.count == 3)
        #expect(treeRows(edited) == treeRows(s))
    }

    @Test func editedSnapshotsRoundTripThroughFiles() throws {
        let s = randomSnapshot(count: 3000, seed: 82)
        let (edited, _) = s.removing(Array(stride(from: 5, to: 3000, by: 97)))
        let loaded = try Snapshot(fileData: edited.fileData())
        #expect(treeRows(loaded) == treeRows(edited))
    }
}

private func depth(_ s: Snapshot, _ node: Int) -> Int {
    var d = 0, n = node
    while n != 0 { n = Int(s.parent[n]); d += 1 }
    return d
}
