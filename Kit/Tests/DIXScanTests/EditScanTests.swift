//
//  EditScanTests.swift
//  DIXScanTests
//
//  Snapshot.removing / replacingSubtree checked against the real thing: the
//  same change made on disk, then a fresh scan of the whole tree. The trees
//  must agree entry for entry (names, sizes, flags, kinds, child order) and
//  the hard-link tables must name the same files, including which link
//  keeps the size.
//
//  GPL v3
//

import Foundation
import Testing
import DIXCore
@testable import DIXScan

/// deterministic PRNG (SplitMix64), so failures reproduce
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct Row: Hashable, CustomStringConvertible {
    var path: String
    var allocated: UInt64
    var logical: UInt64
    var flags: UInt16
    var kind: FileKind
    var childCount: UInt32
    var description: String { "\(path) a=\(allocated) l=\(logical) f=\(flags) k=\(kind.name) c=\(childCount)" }
}

/// depth-first, children in snapshot order, paths relative to the root
private func rows(_ s: Snapshot) -> [Row] {
    var out: [Row] = []
    var stack: [(Int, String)] = [(0, "")]
    while let (node, path) = stack.popLast() {
        out.append(Row(path: path, allocated: s.allocatedSize[node], logical: s.logicalSize[node],
                       flags: s.flags[node].rawValue, kind: s.kind(of: node), childCount: s.childCount[node]))
        for child in s.children(of: node).reversed() {
            stack.append((child, path.isEmpty ? s.name(of: child) : path + "/" + s.name(of: child)))
        }
    }
    return out
}

/// hard-linked files that still have several links in the snapshot. (An
/// edited snapshot keeps listing a file whose other links were removed; a
/// fresh scan sees its link count is 1 now. Both are right about its size.)
private func links(_ s: Snapshot) -> Set<String> {
    var groups: [String: [String]] = [:]
    for link in s.hardLinks {
        let node = Int(link.node)
        let keeper = s.flags[node].contains(.hardLinkDuplicate) ? "dup" : "keeper"
        groups["\(link.device):\(link.fileID)", default: []].append("\(s.path(of: node).dropFirst(s.rootPath.count)) \(keeper)")
    }
    return Set(groups.filter { $0.value.count > 1 }.map { "\($0.key) \($0.value.sorted())" })
}

private func expectSameTree(_ edited: Snapshot, _ fresh: Snapshot, _ context: String) {
    #expect(edited.validate() == nil, "\(context): \(edited.validate() ?? "")")
    let a = rows(edited), b = rows(fresh)
    if a != b {
        let i = (0 ..< min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
        Issue.record("\(context): trees differ at row \(i): \(i < a.count ? a[i].description : "-") vs \(i < b.count ? b[i].description : "-") (\(a.count) vs \(b.count) rows)")
    }
    #expect(links(edited) == links(fresh), "\(context): hard links differ: only edited \(links(edited).subtracting(links(fresh)).sorted()), only fresh \(links(fresh).subtracting(links(edited)).sorted())")
}

private func scan(_ path: String) throws -> Snapshot {
    try Scanner(path: path, options: .init(workerCount: 4)).scan().snapshot
}

/// A random tree on disk: nested folders, files whose sizes often tie (so
/// names decide the order), and hard links across folders.
private func makeRandomTree(_ f: Fixture, rng: inout SplitMix) -> [String] {
    var files: [String] = []
    let sizes = [0, 1, 100, 4096, 4097, 9000, 20_000, 70_000]
    func fill(_ dir: String, depth: Int) {
        for i in 0 ..< Int.random(in: 0 ... 7, using: &rng) {
            let path = dir + "/f\(i)" + [".txt", ".swift", ".bin", ""][Int.random(in: 0 ..< 4, using: &rng)]
            f.file(path, bytes: sizes[Int.random(in: 0 ..< sizes.count, using: &rng)])
            files.append(path)
        }
        guard depth < 4 else { return }
        for i in 0 ..< Int.random(in: 0 ... max(0, 4 - depth), using: &rng) {
            let sub = dir + "/d\(i)"
            f.dir(sub)
            fill(sub, depth: depth + 1)
        }
    }
    f.dir("t")
    fill("t", depth: 0)
    // hard links: some files get 1-3 more names, anywhere
    var directories = ["t"]
    if let e = FileManager.default.enumerator(atPath: f.path("t")) {
        while let p = e.nextObject() as? String {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: f.path("t/" + p), isDirectory: &isDir), isDir.boolValue { directories.append("t/" + p) }
        }
    }
    for i in 0 ..< min(files.count, 8) {
        let target = files[Int.random(in: 0 ..< files.count, using: &rng)]
        for j in 0 ..< Int.random(in: 1 ... 3, using: &rng) {
            let dir = directories[Int.random(in: 0 ..< directories.count, using: &rng)]
            // names chosen so the new link sometimes sorts before the original
            let name = dir + "/" + (Bool.random(using: &rng) ? "a-link\(i)-\(j)" : "z-link\(i)-\(j)")
            if link(f.path(target), f.path(name)) == 0 { files.append(name) }
        }
    }
    return files
}

@Suite struct EditScanTests {
    @Test func randomRemovalsMatchAFreshScan() throws {
        var rng = SplitMix(state: 0xF00D)
        for round in 0 ..< 12 {
            let f = Fixture("edit-rm")
            _ = makeRandomTree(f, rng: &rng)
            let root = f.path("t")
            var s = try scan(root)
            for step in 0 ..< 5 where s.nodeCount > 1 {
                var picks: [Int] = []
                for _ in 0 ..< Int.random(in: 1 ... 4, using: &rng) {
                    let node = Int.random(in: 1 ..< s.nodeCount, using: &rng)
                    picks.append(node)
                    if Int.random(in: 0 ..< 3, using: &rng) == 0, s.parent[node] != 0 { picks.append(Int(s.parent[node])) }
                }
                // keepers of hard links are the interesting case: pick one when there is one
                if let keeper = s.hardLinks.first(where: { !s.flags[Int($0.node)].contains(.hardLinkDuplicate) }),
                   Bool.random(using: &rng) {
                    picks.append(Int(keeper.node))
                }
                for node in picks { try? FileManager.default.removeItem(atPath: s.path(of: node)) }
                let (edited, map) = s.removing(picks)
                for node in picks { #expect(map[node] == .max) }
                expectSameTree(edited, try scan(root), "round \(round) step \(step)")
                s = edited
            }
        }
    }

    @Test func randomReplacementsMatchAFreshScan() throws {
        var rng = SplitMix(state: 0xBEEF)
        for round in 0 ..< 12 {
            let f = Fixture("edit-re")
            var files = makeRandomTree(f, rng: &rng)
            let root = f.path("t")
            var s = try scan(root)
            for step in 0 ..< 5 {
                let folders = (0 ..< s.nodeCount).filter { s.isDirectory($0) }
                let node = folders[Int.random(in: 0 ..< folders.count, using: &rng)]
                let folder = s.path(of: node)
                let relative = "t" + folder.dropFirst(root.count)
                let inside = files.filter { $0.hasPrefix(relative + "/") }
                // already hard-linked files only: a file that had one link when
                // scanned has no inode on record, so a new link to it from inside
                // the folder cannot be recognized (it counts twice until a full rescan)
                let linked = Set(s.hardLinks.map { "t" + s.path(of: Int($0.node)).dropFirst(root.count) })
                let outside = files.filter { !$0.hasPrefix(relative + "/") && linked.contains($0) }
                // change things inside the folder only
                if let victim = inside.randomElement(using: &rng) {
                    unlink(f.path(victim))          // may be a hard-link keeper
                    files.removeAll { $0 == victim }
                }
                for i in 0 ..< Int.random(in: 0 ... 3, using: &rng) {
                    let name = relative + "/new\(step)-\(i).txt"
                    f.file(name, bytes: Int.random(in: 0 ... 30_000, using: &rng))
                    files.append(name)
                }
                if Bool.random(using: &rng) {
                    f.dir(relative + "/newdir\(step)")
                    f.file(relative + "/newdir\(step)/x", bytes: 5000)
                    files.append(relative + "/newdir\(step)/x")
                }
                if let target = outside.randomElement(using: &rng) {
                    // a link from inside to a file outside: the group spans the boundary
                    let name = relative + "/" + (Bool.random(using: &rng) ? "0-link\(step)" : "~link\(step)")
                    if link(f.path(target), f.path(name)) == 0 { files.append(name) }
                }
                let fresh = try scan(folder)
                let (edited, map) = s.replacingSubtree(at: node, with: fresh)
                #expect(edited.name(of: Int(map[node])) == s.name(of: node))
                expectSameTree(edited, try scan(root), "round \(round) step \(step) at \(relative)")
                s = edited
            }
        }
    }

    @Test func editsOfTheStandardFixture() throws {
        let f = Fixture.standard()
        let s = try scan(f.root)
        // trash the keeper of the four-name hard link, and the deep tree with its ancestor
        let keeper = try #require(s.node("links/a/w"))
        let deep = try #require(s.node("deep"))
        let deepChild = Int(s.firstChild[deep])
        try FileManager.default.removeItem(atPath: s.path(of: keeper))
        let (edited, _) = s.removing([keeper, deepChild, deep])
        // the deep tree is past PATH_MAX, too deep to delete here: drop it from the fresh scan instead
        let freshAll = try scan(f.root)
        let (freshTrimmed, _) = freshAll.removing([try #require(freshAll.node("deep"))])
        expectSameTree(edited, freshTrimmed, "standard fixture")
        let x = try #require(edited.node("links/a/x"))
        #expect(!edited.flags[x].contains(.hardLinkDuplicate) && edited.allocatedSize[x] > 0)
        // and survive a file round trip, hard-link table included
        let loaded = try Snapshot(fileData: edited.fileData())
        #expect(loaded.hardLinks == edited.hardLinks)
        #expect(rows(loaded) == rows(edited))
    }
}
