import Testing
@testable import DIXCore

@Test func tinySnapshotValidates() {
    // root/ { b.txt (8), a/ { c (4) } } -- children sorted by allocated size
    let names = Array("rootab.txtc".utf8)
    let snap = Snapshot(
        rootPath: "/tmp/root", scanDate: .now, volume: nil,
        parent:        [0, 0, 0, 1],
        firstChild:    [1, 3, 0, 0],
        childCount:    [2, 1, 0, 0],
        allocatedSize: [12, 4, 8, 4],
        logicalSize:   [12, 4, 8, 4],
        nameOffset:    [0, 4, 5, 10],
        nameLength:    [4, 1, 5, 1],
        kindIndex:     [0, 0, 1, 1],
        flags:         [.directory, .directory, [], []],
        nameBytes: names,
        kinds: [FileKind(identifier: "public.folder", name: "Folder"), FileKind(identifier: "public.data", name: "Document")])
    // children of root are a/ (4) and b.txt (8): not sorted descending -> invalid
    #expect(snap.validate() != nil)
    var sorted = snap
    sorted.firstChild = [1, 3, 0, 0]
    // swap order: b.txt first
    sorted.parent = [0, 0, 0, 2]
    sorted.firstChild = [1, 0, 3, 0]
    sorted.childCount = [2, 0, 1, 0]
    sorted.allocatedSize = [12, 8, 4, 4]
    sorted.logicalSize = [12, 8, 4, 4]
    sorted.nameOffset = [0, 5, 4, 10]
    sorted.nameLength = [4, 5, 1, 1]
    sorted.kindIndex = [0, 1, 0, 1]
    sorted.flags = [.directory, [], .directory, []]
    #expect(sorted.validate() == nil)
    #expect(sorted.path(of: 3) == "/tmp/root/a/c")
    #expect(sorted.name(of: 1) == "b.txt")
}
