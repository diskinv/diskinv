import AppKit
import Foundation
import Testing
import DIXCore
import DIXScan
@testable import DIXTreemap
@testable import DIXApp

// MARK: - zoom stack and selection (DocumentModel)

@Test func zoomStackInOutAndTo() throws {
    let s = editFixture()
    let m = DocumentModel(snapshot: s)
    let big = try #require(s.findNode(path: "/fx/root/big"))
    let sub = try #require(s.findNode(path: "/fx/root/big/sub"))
    var changes: [DocumentModel.Change] = []
    m.observe { changes.append($0) }

    #expect(!m.canZoomIn)
    m.select(big)
    #expect(m.canZoomIn)
    m.zoomIn()
    #expect(m.zoomStack == [0, big])
    #expect(m.selection == nil)              // the zoomed folder itself isn't a row
    m.select(sub)
    m.zoomIn()
    #expect(m.zoomStack == [0, big, sub])
    m.zoomOut()
    #expect(m.zoomStack == [0, big])
    #expect(m.selection == sub)              // zooming out selects the folder zoomed out of
    m.zoomOut(to: 0)
    #expect(m.zoomStack == [0])
    #expect(m.selection == big)
    #expect(changes.contains(.zoom))
    // selecting outside the zoomed folder is refused
    m.select(sub); m.zoomIn()
    let mid = try #require(s.findNode(path: "/fx/root/mid.mov"))
    m.select(mid)
    #expect(m.selection == nil)
}

@Test func selectionOriginPreventsEchoes() throws {
    let s = editFixture()
    let m = DocumentModel(snapshot: s)
    let a = try #require(s.findNode(path: "/fx/root/big/a.jpg"))
    let outlineSide = NSObject(), treemapSide = NSObject()
    var seenBy: [(Bool, Bool)] = []
    m.observe { c in
        if c == .selection { seenBy.append((m.selectionOrigin === outlineSide, m.selectionOrigin === treemapSide)) }
    }
    m.select(a, origin: outlineSide)
    m.select(a, origin: treemapSide)     // same node: no change posted
    #expect(seenBy.count == 1)
    #expect(seenBy[0].0)
}

@Test func highlightClearsWhenAnotherKindIsSelected() throws {
    let s = editFixture()
    let m = DocumentModel(snapshot: s)
    let a = try #require(s.findNode(path: "/fx/root/big/a.jpg"))
    let d = try #require(s.findNode(path: "/fx/root/small/d.txt"))
    m.highlightKind("JPEG image")
    m.select(a)
    #expect(m.highlightedKind == "JPEG image")
    m.select(d)
    #expect(m.highlightedKind == nil)
}

@Test func hiddenPackageSelectionMovesToThePackage() throws {
    let s = SnapshotBuilder.build(.folder("root", [
        .folder("Thing.app", [.folder("Contents", [.file("bin", size: 900, kind: "Unix executable")])],
                flags: .package, kind: "Application"),
        .file("x.txt", size: 10, kind: "Plain Text"),
    ]), rootPath: "/fx/pk")
    let m = DocumentModel(snapshot: s, options: ViewOptions(showPackageContents: true))
    let bin = try #require(s.findNode(path: "/fx/pk/Thing.app/Contents/bin"))
    let app = try #require(s.findNode(path: "/fx/pk/Thing.app"))
    m.select(bin)
    #expect(m.isContainer(app))
    m.setOptions(ViewOptions(showPackageContents: false))
    #expect(m.selection == app)
    #expect(!m.isContainer(app))
    // kind statistics: the package is one "Application" file, its contents don't count
    let stats = m.kindStatistics
    #expect(stats.entry(named: "Application")?.fileCount == 1)
    #expect(stats.entry(named: "Unix executable") == nil)
}

@Test func replaceSnapshotKeepsZoomAndSelectionThroughIndexMap() throws {
    let s = editFixture()
    let m = DocumentModel(snapshot: s)
    let big = try #require(s.findNode(path: "/fx/root/big"))
    let a = try #require(s.findNode(path: "/fx/root/big/a.jpg"))
    let b = try #require(s.findNode(path: "/fx/root/big/b.jpg"))
    m.select(big); m.zoomIn(); m.select(b)
    let (t, map) = SnapshotEdits.removing(s, [a])
    m.replaceSnapshot(t, indexMap: map)
    #expect(m.snapshot.path(of: m.zoomedNode) == "/fx/root/big")
    #expect(m.selection.map { m.snapshot.path(of: $0) } == "/fx/root/big/b.jpg")
    #expect(m.lastIndexMap == map)
}

// MARK: - progress text

@Test func progressTextWithKnownTotal() {
    var rate = ScanEstimate.Rate()
    _ = ScanEstimate.status(rootPath: "/Users/x/b", displayName: "b", items: 0, bytes: 0, currentPath: "/Users/x/b",
                            expectedItems: 1000, elapsed: 0, rate: &rate)
    let s = ScanEstimate.status(rootPath: "/Users/x/b", displayName: "b", items: 420, bytes: 6_100_000_000,
                                currentPath: "/Users/x/b/a/cowboy", expectedItems: 1000, elapsed: 4.2, rate: &rate)
    #expect(s.title == "Scanning “b” — 42% · about 5 s left" || s.title.hasPrefix("Scanning “b” — 42% · "))
    #expect(s.fraction == 0.42)
    #expect(s.folder == "a/cowboy")
    #expect(s.detail == "420 items · 6.1 GB · 0:04")
}

@Test func progressTextWithUnknownTotal() {
    var rate = ScanEstimate.Rate()
    let s = ScanEstimate.status(rootPath: "/", displayName: "Macintosh HD", items: 1_204_311, bytes: 41_200_000_000,
                                currentPath: "/Users/x", expectedItems: nil, elapsed: 72, rate: &rate)
    #expect(s.title == "Scanning “Macintosh HD”")
    #expect(s.fraction == nil)
    #expect(s.folder == "Users/x")
    #expect(s.detail == "1,204,311 items · 41.2 GB · 1:12")
}

@Test func progressCapsAndTimeLeftWording() {
    #expect(ScanEstimate.timeLeft(4) == "a few seconds left")
    #expect(ScanEstimate.timeLeft(22) == "about 20 s left")
    #expect(ScanEstimate.timeLeft(130) == "about 2 min left")
    var rate = ScanEstimate.Rate()
    _ = ScanEstimate.status(rootPath: "/a", displayName: "a", items: 0, bytes: 0, currentPath: "/a", expectedItems: 10, elapsed: 0, rate: &rate)
    let over = ScanEstimate.status(rootPath: "/a", displayName: "a", items: 15, bytes: 0, currentPath: "/a", expectedItems: 10, elapsed: 3, rate: &rate)
    #expect(over.fraction == 0.99)
    #expect(over.title.hasSuffix("almost done"))
}

@Test func rememberedItemCounts() throws {
    let defaults = try #require(UserDefaults(suiteName: "dixapp-tests-\(UUID().uuidString)"))
    let memory = ScanCountMemory(defaults: defaults)
    #expect(memory.count(forFolder: "/x") == nil)
    memory.record(1234, forFolder: "/x")
    #expect(memory.count(forFolder: "/x") == 1234)
    for i in 0 ..< 120 { memory.record(i + 1, forFolder: "/f\(i)", date: Date(timeIntervalSince1970: Double(i))) }
    #expect((defaults.dictionary(forKey: ScanCountMemory.defaultsKey)?.count ?? 0) == ScanCountMemory.maxRememberedFolders)
    #expect(memory.count(forFolder: "/f0") == nil)     // the oldest were dropped
}

// MARK: - hover text

@Test func hoverTextForFilesCloudAndMergedAreas() throws {
    let s = SnapshotBuilder.build(.folder("root", [
        .folder("Docs", [.file("report.pdf", size: 1_200_000, kind: "PDF document")]),
        .file("movie.mov", size: 0, logical: 5_000_000_000, kind: "QuickTime movie", flags: .cloudPlaceholder),
    ]), rootPath: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs")
    let pdf = try #require(s.findNode(path: s.rootPath + "/Docs/report.pdf"))
    let t = HoverText.text(for: pdf, snapshot: s, sizeMode: .allocated)
    #expect(t.name == "report.pdf (Docs)")
    #expect(t.detail == "PDF document, 1.2 MB")
    let movie = try #require(s.findNode(path: s.rootPath + "/movie.mov"))
    let c = HoverText.text(for: movie, snapshot: s, sizeMode: .logical)
    #expect(c.detail == "QuickTime movie, 5.0 GB — in iCloud, not on this Mac")
    #expect(HoverText.cloudProvider(forPath: "/Users/x/Library/CloudStorage/Dropbox/a") == "Dropbox")
    #expect(HoverText.cloudProvider(forPath: "/Users/x/Library/CloudStorage/OneDrive-Personal/a") == "OneDrive")

    let b = MergedBreakdown(fileCount: 70, folderCount: 1, size: 14_000_000,
                            kinds: [.init(kind: 1, name: "JavaScript", count: 35, size: 9_000_000),
                                    .init(kind: 2, name: "JSON", count: 20, size: 3_000_000),
                                    .init(kind: 3, name: "Markdown", count: 10, size: 1_000_000),
                                    .init(kind: 4, name: "Text", count: 5, size: 1_000_000)])
    let m = HoverText.mergedText(b, folderName: "node_modules")
    #expect(m.name == "70 small files in 1 folder: 35 JavaScript, 20 JSON, 10 Markdown, … (node_modules)")
    #expect(m.detail == "14.0 MB")
}

@Test func sizesFormatLikeTheOriginal() {
    #expect(Format.size(0) == "0 Bytes")
    #expect(Format.size(999) == "999 Bytes")
    #expect(Format.size(812_400) == "812 kB")
    #expect(Format.size(1_234_567) == "1.2 MB")
    #expect(Format.size(41_200_000_000) == "41.2 GB")
}

// MARK: - the window: selection sync, zoom, trash, refresh (no window is shown)

/// a folder of real files under the scratchpad (or the temp dir), never anything else
func makeFixtureFolder() throws -> URL {
    let base = ProcessInfo.processInfo.environment["DIX_FIXTURES"].map(URL.init(fileURLWithPath:))
        ?? FileManager.default.temporaryDirectory
    let root = base.appendingPathComponent("dixapp-fixture-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("photos/2024"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("code"), withIntermediateDirectories: true)
    try Data(count: 400_000).write(to: root.appendingPathComponent("photos/2024/a.jpg"))
    try Data(count: 300_000).write(to: root.appendingPathComponent("photos/2024/b.jpg"))
    try Data(count: 900_000).write(to: root.appendingPathComponent("movie.mov"))
    for i in 0 ..< 30 { try Data(count: 100 + i).write(to: root.appendingPathComponent("code/f\(i).js")) }
    return root
}

@MainActor
@Test func windowSelectionSyncZoomTrashAndRefreshOnAFixture() throws {
    _ = NSApplication.shared
    let root = try makeFixtureFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let scan = try DIXScan.Scanner(path: root.path).scan()
    let doc = ScanDocument(snapshot: scan.snapshot)
    doc.makeWindowControllers()
    let wc = try #require(doc.windowController)
    wc.window?.setContentSize(NSSize(width: 1000, height: 700))
    wc.window?.contentView?.layoutSubtreeIfNeeded()
    wc.treemapView.renderNow()
    let m = wc.model
    let s = m.snapshot
    let rootPath = s.rootPath

    // outline -> document -> treemap
    let a = try #require(s.findNode(path: rootPath + "/photos/2024/a.jpg"))
    m.select(a)
    let row = wc.outline.outlineView.selectedRow
    #expect(row >= 0)
    #expect((wc.outline.outlineView.item(atRow: row) as? NodeItem)?.node == a)    // ancestors expanded
    #expect(wc.treemapView.selectedNode == a)
    #expect(wc.treemapView.selectedCell != nil)

    // treemap click -> document -> outline
    let movie = try #require(s.findNode(path: rootPath + "/movie.mov"))
    let movieRect = try #require(wc.treemapView.rect(for: movie))
    let hit = wc.treemapView.hit(at: CGPoint(x: movieRect.midX, y: movieRect.midY))
    wc.treemapView(wc.treemapView, clicked: hit, clickCount: 1)
    #expect(m.selection == movie)
    #expect((wc.outline.outlineView.item(atRow: wc.outline.outlineView.selectedRow) as? NodeItem)?.node == movie)
    // the kind table follows the selected file
    let kindRow = wc.kinds.tableView.selectedRow
    #expect(kindRow >= 0 && wc.kinds.statistics[kindRow].name == s.kind(of: movie).name)

    // zoom into photos via the outline's double-click path
    let photos = try #require(s.findNode(path: rootPath + "/photos"))
    m.select(photos)
    wc.zoomIn(nil)
    #expect(m.zoomedNode == photos)
    wc.treemapView.renderNow()
    #expect(wc.treemapView.layout?.root == photos)
    #expect(wc.outline.outlineView.numberOfRows >= 1)

    // move a.jpg "to the Trash": the fixture file is moved into a fixture trash folder
    let trash = root.appendingPathComponent(".fixture-trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let a2 = try #require(m.snapshot.findNode(path: rootPath + "/photos/2024/a.jpg"))
    let b2 = try #require(m.snapshot.findNode(path: rootPath + "/photos/2024/b.jpg"))
    m.select(b2)
    let before = m.snapshot.allocatedSize[0]
    let aSize = m.snapshot.allocatedSize[a2]
    wc.performTrash(a2) { url in
        #expect(url.path.hasPrefix(ScanOperation.realPath(root.path)))      // only ever the fixture
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
    }
    #expect(m.snapshot.validate() == nil)
    #expect(m.snapshot.findNode(path: rootPath + "/photos/2024/a.jpg") == nil)
    #expect(m.snapshot.allocatedSize[0] == before - aSize)
    #expect(m.snapshot.path(of: m.zoomedNode) == rootPath + "/photos")       // zoom kept
    #expect(m.selection.map { m.snapshot.path(of: $0) } == rootPath + "/photos/2024/b.jpg")   // selection kept
    #expect((wc.outline.outlineView.item(atRow: wc.outline.outlineView.selectedRow) as? NodeItem)?.node == m.selection)

    // refresh a folder after adding a file to it: rescan just that folder and splice it in
    try Data(count: 2_000_000).write(to: root.appendingPathComponent("photos/2024/new.raw"))
    let folder = try #require(m.snapshot.findNode(path: rootPath + "/photos/2024"))
    let rescan = try DIXScan.Scanner(path: root.path + "/photos/2024").scan()
    wc.applyRefresh(rescan, at: folder, rootPath: rootPath, scannedPath: rootPath + "/photos/2024", before: m.snapshot)
    #expect(m.snapshot.validate() == nil)
    let newRaw = try #require(m.snapshot.findNode(path: rootPath + "/photos/2024/new.raw"))
    #expect(m.snapshot.allocatedSize[newRaw] >= 2_000_000)
    #expect(m.snapshot.path(of: m.zoomedNode) == rootPath + "/photos")
    #expect(m.snapshot.findNode(path: rootPath + "/photos/2024/a.jpg") == nil)
    doc.close()
}

@MainActor
@Test func selectionListFiltersAndSorts() throws {
    let s = editFixture()
    let q = SelectionListController.Query(kindNames: ["JPEG image"], search: "", scope: .all, sortKey: "size",
                                          ascending: false, sizeMode: .allocated, showPackageContents: false)
    let rows = SelectionListController.rows(for: q, in: s).map { s.name(of: Int($0)) }
    #expect(rows == ["a.jpg", "b.jpg"])
    var q2 = q
    q2.kindNames = nil
    q2.search = "txt"
    q2.scope = .name
    q2.sortKey = "displayName"
    q2.ascending = true
    #expect(SelectionListController.rows(for: q2, in: s).map { s.name(of: Int($0)) } == ["c.txt", "d.txt"])
}

@MainActor
@Test func mergedClickSelectsLargestMemberAndFramesTheGroup() throws {
    _ = NSApplication.shared
    // a folder with many tiny files next to a huge one: the tiny ones merge
    var items: [FixtureItem] = [.file("huge.bin", size: 2_000_000, kind: "Data")]
    for i in 0 ..< 200 { items.append(.file("t\(i).js", size: UInt64(100 + i), kind: "JavaScript")) }
    let s = SnapshotBuilder.build(.folder("root", items), rootPath: "/fx/merge")
    let doc = ScanDocument(snapshot: s)
    doc.makeWindowControllers()
    let wc = try #require(doc.windowController)
    wc.window?.setContentSize(NSSize(width: 900, height: 600))
    wc.window?.contentView?.layoutSubtreeIfNeeded()
    wc.treemapView.renderNow()
    let layout = try #require(wc.treemapView.layout)
    let group = try #require(layout.mergedGroups.first)
    wc.treemapView(wc.treemapView, clicked: .merged(group, cell: group.cell), clickCount: 1)
    let sel = try #require(wc.model.selection)
    #expect(sel == layout.mergedMembers(of: group).first)
    #expect(s.name(of: sel).hasPrefix("t"))
    #expect(wc.treemapView.selectedCell == group.cell)
    doc.close()
}
