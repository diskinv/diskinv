//
//  EditBench.swift
//  dix-scan
//
//  dix-scan --bench-edit <file.dixsnap>: times Snapshot.removing and
//  Snapshot.replacingSubtree on a real snapshot. Replacement subtrees are
//  copied out of the snapshot itself (as a fresh scan of an unchanged folder
//  would produce them), so no disk access is needed.
//
//  GPL v3
//

import Foundation
import DIXCore

/// The subtree at `node` as a snapshot of its own (BFS order), as a scan of
/// that folder would give it.
func extractSubtree(_ s: Snapshot, at node: Int) -> Snapshot {
    var order = [node]
    var head = 0
    while head < order.count {
        order.append(contentsOf: s.children(of: order[head]))
        head += 1
    }
    var index: [Int: Int] = [:]
    index.reserveCapacity(order.count)
    for (i, n) in order.enumerated() { index[n] = i }
    var names: [UInt8] = []
    var parent: [UInt32] = [], firstChild: [UInt32] = [], childCount: [UInt32] = []
    var nameOffset: [UInt32] = [], nameLength: [UInt16] = []
    for (i, n) in order.enumerated() {
        parent.append(i == 0 ? 0 : UInt32(index[Int(s.parent[n])]!))
        childCount.append(s.childCount[n])
        firstChild.append(s.childCount[n] > 0 ? UInt32(index[Int(s.firstChild[n])]!) : 0)
        let start = Int(s.nameOffset[n])
        nameOffset.append(UInt32(names.count))
        nameLength.append(s.nameLength[n])
        names.append(contentsOf: s.nameBytes[start ..< start + Int(s.nameLength[n])])
    }
    let links = s.hardLinks.compactMap { link in
        index[Int(link.node)].map { HardLink(node: UInt32($0), device: link.device, fileID: link.fileID) }
    }.sorted { $0.node < $1.node }
    var flags = order.map { s.flags[$0] }
    flags[0].subtract([.mountPoint, .cloudPlaceholder])
    return Snapshot(rootPath: s.path(of: node), scanDate: s.scanDate, volume: s.volume,
                    parent: parent, firstChild: firstChild, childCount: childCount,
                    allocatedSize: order.map { s.allocatedSize[$0] }, logicalSize: order.map { s.logicalSize[$0] },
                    nameOffset: nameOffset, nameLength: nameLength, kindIndex: order.map { s.kindIndex[$0] },
                    flags: flags, nameBytes: names, kinds: s.kinds, hardLinks: links)
}

func benchEdits(_ s: Snapshot) {
    func time<T>(_ label: String, repeat count: Int = 5, _ body: () -> T) -> T {
        var best = Double.infinity
        var result: T?
        for _ in 0 ..< count {
            let t0 = Date()
            result = body()
            best = min(best, Date().timeIntervalSince(t0))
        }
        print("  " + label.padding(toLength: 56, withPad: " ", startingAt: 0) + String(format: "%8.1f ms (best of %d)", best * 1000, count))
        return result!
    }
    func subtreeSize(_ node: Int) -> Int {
        var count = 0, stack = [node]
        while let n = stack.popLast() { count += 1; stack.append(contentsOf: s.children(of: n)) }
        return count
    }
    print("snapshot: \(s.nodeCount) nodes, \(s.hardLinks.count) hard-linked")
    var rng = SystemRandomNumberGenerator()
    let files = (0 ..< s.nodeCount).filter { !s.isDirectory($0) }
    let folders = (1 ..< s.nodeCount).filter { s.isDirectory($0) }
    // the deepest file, a big folder, a mid-size folder
    let deepFile = files.max { s.path(of: $0).count < s.path(of: $1).count } ?? 1
    let big = Int(s.firstChild[0])     // the root's largest child
    let most = s.children(of: 0).max { subtreeSize($0) < subtreeSize($1) } ?? big     // and the one with most nodes
    let mid = folders.min { abs(subtreeSize($0) - 10_000) < abs(subtreeSize($1) - 10_000) } ?? big

    func check(_ r: (snapshot: Snapshot, indexMap: [UInt32]), _ what: String) {
        if let problem = r.snapshot.validate() { print("  INVALID after \(what): \(problem)") }
    }
    print("removing:")
    check(time("one deep file") { s.removing([deepFile]) }, "file")
    check(time("root's largest child (\(subtreeSize(big)) nodes)") { s.removing([big]) }, "big")
    check(time("root's child with most nodes (\(subtreeSize(most)) nodes)") { s.removing([most]) }, "most")
    check(time("a ~10k-node folder (\(subtreeSize(mid)) nodes)") { s.removing([mid]) }, "mid")
    let thousand = (0 ..< 1000).map { _ in files.randomElement(using: &rng)! }
    check(time("1000 random files") { s.removing(thousand) }, "1000")
    let hundredFolders = (0 ..< 100).map { _ in folders.randomElement(using: &rng)! }
    check(time("100 random folders") { s.removing(hundredFolders) }, "100 folders")

    print("replacing (with an identical copy of the subtree):")
    let midTree = extractSubtree(s, at: mid)
    let midResult = time("a ~10k-node folder (\(subtreeSize(mid)) nodes)") { s.replacingSubtree(at: mid, with: midTree) }
    check(midResult, "replace mid")
    let parentOfDeep = Int(s.parent[deepFile])
    let smallTree = extractSubtree(s, at: parentOfDeep)
    check(time("the deepest file's folder (\(subtreeSize(parentOfDeep)) nodes)") {
        s.replacingSubtree(at: parentOfDeep, with: smallTree)
    }, "replace small")
    let bigTree = extractSubtree(s, at: big)
    check(time("root's largest child (\(subtreeSize(big)) nodes)") { s.replacingSubtree(at: big, with: bigTree) }, "replace big")
    let mostTree = extractSubtree(s, at: most)
    check(time("root's child with most nodes (\(subtreeSize(most)) nodes)") { s.replacingSubtree(at: most, with: mostTree) }, "replace most")
    print("validate() alone:")
    _ = time("validate", repeat: 3) { s.validate() }
}
