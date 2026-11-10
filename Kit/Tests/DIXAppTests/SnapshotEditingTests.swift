import Testing
import DIXCore
import DIXTreemap
@testable import DIXApp

/// root/ { big/ { a.jpg 400, b.jpg 300, sub/ { c.txt 50 } }, mid.mov 500, small/ { d.txt 10 } }
func editFixture() -> Snapshot {
    SnapshotBuilder.build(.folder("root", [
        .folder("big", [
            .file("a.jpg", size: 400, kind: "JPEG image"),
            .file("b.jpg", size: 300, kind: "JPEG image"),
            .folder("sub", [.file("c.txt", size: 50, kind: "Plain Text")]),
        ]),
        .file("mid.mov", size: 500, kind: "Movie"),
        .folder("small", [.file("d.txt", size: 10, kind: "Plain Text")]),
    ]), rootPath: "/fx/root")
}

@Test func removingAFileShrinksAncestorsAndResorts() throws {
    let s = editFixture()
    #expect(s.validate() == nil)
    let big = try #require(s.findNode(path: "/fx/root/big"))
    let a = try #require(s.findNode(path: "/fx/root/big/a.jpg"))
    #expect(s.allocatedSize[big] == 750)
    let (t, map) = SnapshotEdits.removing(s, [a])
    #expect(t.validate() == nil)
    #expect(t.nodeCount == s.nodeCount - 1)
    #expect(map[a] == .max)
    #expect(t.allocatedSize[0] == 860)
    // big is now 350 < mid.mov 500: re-sorted after it
    let newBig = Int(map[big])
    #expect(t.name(of: newBig) == "big")
    #expect(t.allocatedSize[newBig] == 350)
    #expect(t.children(of: 0).map { t.name(of: $0) } == ["mid.mov", "big", "small"])
    // every surviving node maps to a node with the same path
    for old in 0 ..< s.nodeCount where map[old] != .max {
        #expect(t.path(of: Int(map[old])) == s.path(of: old))
    }
}

@Test func removingAFolderRemovesItsSubtree() throws {
    let s = editFixture()
    let big = try #require(s.findNode(path: "/fx/root/big"))
    let c = try #require(s.findNode(path: "/fx/root/big/sub/c.txt"))
    let (t, map) = SnapshotEdits.removing(s, [c, big])   // nested: removed once
    #expect(t.validate() == nil)
    #expect(t.nodeCount == s.nodeCount - 5)
    #expect(map[big] == .max && map[c] == .max)
    #expect(t.allocatedSize[0] == 510)
    #expect(t.findNode(path: "/fx/root/big") == nil)
    #expect(t.findNode(path: "/fx/root/small/d.txt") != nil)
}

@Test func replacingASubtreeSplicesItIn() throws {
    let s = editFixture()
    let small = try #require(s.findNode(path: "/fx/root/small"))
    let rescanned = SnapshotBuilder.build(.folder("whatever", [
        .file("d.txt", size: 10, kind: "Plain Text"),
        .file("new.zip", size: 2000, kind: "ZIP archive"),
    ]), rootPath: "/fx/root/small")
    let (t, map) = SnapshotEdits.replacingSubtree(s, at: small, with: rescanned)
    #expect(t.validate() == nil)
    #expect(t.allocatedSize[0] == 1260 + 2000)
    let newSmall = Int(map[small])
    #expect(t.name(of: newSmall) == "small")
    #expect(t.children(of: 0).first.map { t.name(of: $0) } == "small")      // now the largest
    let zip = try #require(t.findNode(path: "/fx/root/small/new.zip"))
    #expect(t.kind(of: zip).name == "ZIP archive")
    // old contents of the replaced folder are gone from the map
    let d = try #require(s.findNode(path: "/fx/root/small/d.txt"))
    #expect(map[d] == .max)
    #expect(t.findNode(path: "/fx/root/small/d.txt") != nil)
}

@Test func removingOnARealSnapshotStaysValid() throws {
    let s = SyntheticSnapshot.make(seed: 7, scale: 1)
    #expect(s.validate() == nil)
    // remove a few nodes spread across the tree
    let picks = stride(from: 5, to: s.nodeCount, by: max(1, s.nodeCount / 7)).map { $0 }
    let (t, map) = SnapshotEdits.removing(s, picks)
    #expect(t.validate() == nil)
    var removedBytes: UInt64 = 0
    // topmost picks only
    for p in picks where !picks.contains(where: { $0 != p && s.isNode(p, inSubtreeOf: $0) }) {
        removedBytes += s.allocatedSize[p]
    }
    #expect(t.allocatedSize[0] == s.allocatedSize[0] - removedBytes)
    for old in 0 ..< s.nodeCount where map[old] != .max {
        #expect(t.name(of: Int(map[old])) == s.name(of: old))
    }
}
