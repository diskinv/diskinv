import AppKit
import Foundation
import DIXCore
import Testing
@testable import DIXTreemap

// MARK: - fixtures

/// a random folder tree: heavy-tailed sizes, many tiny files, zero-size files, empty folders
func randomTree(seed: UInt64, maxDepth: Int = 4, fanout: Int = 12) -> Snapshot {
    var rng = SplitMix64(seed: seed)
    let kinds = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O"]
    func folder(_ name: String, _ depth: Int) -> FixtureItem {
        var items: [FixtureItem] = []
        let files = rng.int(fanout * 3)
        for i in 0 ..< files {
            let r = rng.unit()
            let size: UInt64 = r < 0.08 ? 0 : r < 0.6 ? UInt64(1 + rng.int(4096)) : UInt64(pow(10, 3 + 6 * rng.unit()))
            items.append(.file("f\(i)", size: size, kind: kinds[rng.int(kinds.count)]))
        }
        if depth < maxDepth {
            for i in 0 ..< rng.int(fanout / 2 + 1) { items.append(folder("d\(i)", depth + 1)) }
        }
        if rng.unit() < 0.1 { items.append(.folder("empty", [])) }
        return .folder(name, items)
    }
    return SnapshotBuilder.build(folder("root", 0))
}

let fixtures: [Snapshot] = [randomTree(seed: 1), randomTree(seed: 2, maxDepth: 5, fanout: 8),
                            randomTree(seed: 3, maxDepth: 2, fanout: 40), SyntheticSnapshot.make(seed: 4)]
let sizes: [(Int, Int, Double)] = [(1000, 650, 1), (333, 777, 1), (1440, 900, 2), (97, 61, 1)]

/// expected pixel area of a child cell, from its share of its parent cell
func expectedArea(_ layout: TreemapLayout, _ cell: TreemapCell) -> Double {
    let parent = layout.cell(cell.parent)
    let model = layout.model
    let total = model.orderedChildren(of: parent.node).reduce(0.0) { $0 + Double(model.size(of: $1)) }
    guard total > 0 else { return Double(parent.rect.area) / Double(model.snapshot.childCount[parent.node]) }
    let size: Double
    if let g = cell.mergedGroup { size = Double(layout.mergedGroups[g].size) } else { size = Double(model.size(of: cell.node)) }
    return Double(parent.rect.area) * size / total
}

// MARK: - colors

@Test func paletteMatchesTheOriginalColorChain() {
    // the original: NSColor(calibratedRed:) -> sRGB -> normalize to 1.8 -> calibrated again -> sRGB in the shader
    func original(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        let c = NSColor(calibratedRed: r, green: g, blue: b, alpha: 1).usingColorSpace(.sRGB)!
        var rr = c.redComponent, gg = c.greenComponent, bb = c.blueComponent
        let f = 1.8 / (rr + gg + bb)
        rr *= f; gg *= f; bb *= f
        var dr = Double(rr), dg = Double(gg), db = Double(bb)
        CushionMath.normalize(&dr, &dg, &db)
        return NSColor(calibratedRed: dr, green: dg, blue: db, alpha: 1).usingColorSpace(.sRGB)!
    }
    let raw: [(CGFloat, CGFloat, CGFloat)] = [(0, 0, 1), (1, 0, 0), (0, 1, 0), (0, 1, 1), (1, 0, 1), (1, 1, 0),
                                             (0.58, 0.58, 1), (1, 0.58, 0.58), (0.58, 1, 0.58), (0.58, 1, 1),
                                             (1, 0.58, 1), (1, 1, 0.58)]
    for (i, c) in raw.enumerated() {
        let o = original(c.0, c.1, c.2), p = TreemapPalette.kindColors[i]
        #expect(abs(Double(o.redComponent) - p.red) < 1e-12)
        #expect(abs(Double(o.greenComponent) - p.green) < 1e-12)
        #expect(abs(Double(o.blueComponent) - p.blue) < 1e-12)
    }
    // every grey (including free space white and other space 0.2 grey) normalizes to the same grey
    for g in [0.6, 0.9, 1.0, 0.2] as [CGFloat] {
        #expect(abs(Double(original(g, g, g).redComponent) - TreemapPalette.grey.red) < 1e-12)
    }
}

@Test func kindsGetPaletteColorsInOrderOfTotalSize() {
    var files: [FixtureItem] = []
    for k in 0 ..< 14 {   // kind k has total size (14 - k) * 1000
        files.append(.file("k\(k)", size: UInt64(14 - k) * 1000, kind: "kind\(k)"))
    }
    let s = SnapshotBuilder.build(.folder("root", files))
    let colors = KindColors(snapshot: s)
    for k in 0 ..< 14 {
        let index = s.kinds.firstIndex { $0.name == "kind\(k)" }!
        #expect(colors.color(forKind: index) == (k < 12 ? TreemapPalette.kindColors[k] : TreemapPalette.grey))
    }
    let swatch = colors.swatch(forKind: 1, pixelWidth: 20, pixelHeight: 12)
    #expect(swatch.width == 20 && swatch.pixel(x: 10, y: 6).r > 0)
}

// MARK: - layout correctness

@Test func everyCellsAreaMatchesItsShare() {
    for snapshot in fixtures {
        let model = TreemapModel(snapshot: snapshot)
        for (w, h, scale) in sizes {
            let layout = model.layout(pixelWidth: w, pixelHeight: h, scale: scale,
                                      options: TreemapOptions(minimumCellArea: 0))
            for i in 1 ..< layout.cellCount {
                let c = layout.cell(i)
                let expected = expectedArea(layout, c)
                // each edge is within half a pixel: off by at most one row and one column
                #expect(abs(Double(c.rect.area) - expected) <= Double(c.rect.width + c.rect.height + 1),
                        "cell \(c.rect) area \(c.rect.area), expected \(expected)")
            }
            // and nothing with a real share is missing
            for i in 0 ..< layout.cellCount where layout.cell(i).role == .container {
                let p = layout.cell(i)
                let total = model.orderedChildren(of: p.node).reduce(0.0) { $0 + Double(model.size(of: $1)) }
                for child in model.orderedChildren(of: p.node) where layout.rect(for: child) == nil && total > 0 {
                    let expected = Double(p.rect.area) * Double(model.size(of: child)) / total
                    #expect(expected <= Double(max(p.rect.width, p.rect.height)))
                }
            }
        }
    }
}

@Test func aTinyFileIsNotDrawnTooBig() {
    // the PR #18 rewrite drew a 20-byte file 250x too big
    var items: [FixtureItem] = [.file("big", size: 50_000_000_000, kind: "A"), .file("tiny", size: 20, kind: "B")]
    for i in 0 ..< 30 { items.append(.file("m\(i)", size: UInt64(1_000_000 * (i + 1)), kind: "C")) }
    let s = SnapshotBuilder.build(.folder("root", items))
    let layout = TreemapModel(snapshot: s).layout(pixelWidth: 1440, pixelHeight: 900,
                                                  options: TreemapOptions(minimumCellArea: 0))
    let tiny = (0 ..< s.nodeCount).first { s.name(of: $0) == "tiny" }!
    #expect((layout.rect(for: tiny)?.area ?? 0) <= 1)
}

/// every pixel is covered by exactly one drawn cell
func checkTiling(_ layout: TreemapLayout) {
    var coverage = [UInt8](repeating: 0, count: layout.pixelWidth * layout.pixelHeight)
    for i in layout.drawnCells {
        let r = layout.cell(i).rect
        #expect(r.x >= 0 && r.y >= 0 && r.maxX <= layout.pixelWidth && r.maxY <= layout.pixelHeight)
        for y in max(0, r.y) ..< min(layout.pixelHeight, r.maxY) {
            for x in max(0, r.x) ..< min(layout.pixelWidth, r.maxX) { coverage[y * layout.pixelWidth + x] &+= 1 }
        }
    }
    let bad = coverage.filter { $0 != 1 }.count
    #expect(bad == 0, "\(bad) pixels not covered exactly once")
    // children lie inside their parent and add up to it
    for i in 0 ..< layout.cellCount where layout.cell(i).role == .container {
        let p = layout.cell(i)
        var sum = 0
        for c in p.children {
            let r = layout.cell(c).rect
            sum += r.area
            #expect(r.x >= p.rect.x && r.y >= p.rect.y && r.maxX <= p.rect.maxX && r.maxY <= p.rect.maxY)
        }
        #expect(sum == p.rect.area)
    }
}

@Test func noGapsNoOverlaps() {
    for snapshot in fixtures {
        let model = TreemapModel(snapshot: snapshot)
        for (w, h, scale) in sizes {
            for minArea in [0.0, 16, 100] {
                checkTiling(model.layout(pixelWidth: w, pixelHeight: h, scale: scale,
                                         options: TreemapOptions(minimumCellArea: minArea)))
            }
        }
    }
}

@Test func mergedCellsCoverExactlyTheirMergedChildren() {
    var mergedSeen = 0
    for snapshot in fixtures {
        let model = TreemapModel(snapshot: snapshot)
        for (w, h, scale) in sizes {
            let merged = model.layout(pixelWidth: w, pixelHeight: h, scale: scale, options: TreemapOptions(minimumCellArea: 16))
            let plain = model.layout(pixelWidth: w, pixelHeight: h, scale: scale, options: TreemapOptions(minimumCellArea: 0))
            let minPx = 16 * scale * scale
            for group in merged.mergedGroups {
                mergedSeen += 1
                let rect = merged.cell(group.cell).rect
                #expect(group.count >= 2)
                var area = 0
                var size: UInt64 = 0
                for member in merged.mergedMembers(of: group) {
                    #expect(Int(snapshot.parent[member]) == group.folder)
                    size += model.size(of: member)
                    // too small to be drawn on its own
                    let folderCell = merged.cell(merged.cell(group.cell).parent)
                    let total = model.orderedChildren(of: group.folder).reduce(0.0) { $0 + Double(model.size(of: $1)) }
                    #expect(Double(folderCell.rect.area) * Double(model.size(of: member)) / total < minPx)
                    // the same child, laid out unmerged, lies inside the merged cell
                    guard let r = plain.rect(for: member) else { continue }
                    #expect(r.x >= rect.x && r.y >= rect.y && r.maxX <= rect.maxX && r.maxY <= rect.maxY)
                    area += r.area
                    // and maps to the merged cell
                    #expect(merged.cellIndex(for: member) == group.cell)
                }
                #expect(area == rect.area, "merged cell \(rect) vs members \(area)")
                #expect(size == group.size)
            }
        }
    }
    #expect(mergedSeen > 50)
}

@Test func mergingKeepsVisibleCellsWhereTheyAre() {
    for snapshot in fixtures {
        let model = TreemapModel(snapshot: snapshot)
        let merged = model.layout(pixelWidth: 1000, pixelHeight: 650, options: TreemapOptions(minimumCellArea: 16))
        let plain = model.layout(pixelWidth: 1000, pixelHeight: 650, options: TreemapOptions(minimumCellArea: 0))
        for i in merged.drawnCells where merged.cell(i).role == .item {
            #expect(plain.rect(for: merged.cell(i).node) == merged.cell(i).rect)
        }
    }
}

// MARK: - hit testing

@Test func hitTestingFindsTheRightCell() {
    for snapshot in fixtures {
        let model = TreemapModel(snapshot: snapshot)
        for (w, h, scale) in sizes {
            let layout = model.layout(pixelWidth: w, pixelHeight: h, scale: scale)
            for i in layout.drawnCells {
                let c = layout.cell(i)
                for (x, y) in [(c.rect.x, c.rect.y), (c.rect.maxX - 1, c.rect.maxY - 1), (c.rect.x + c.rect.width / 2, c.rect.y + c.rect.height / 2)] {
                    let hit = layout.hitTest(pixelX: x, y: y)
                    #expect(hit?.cell == i)
                    switch hit {
                    case .node(let n, _): #expect(n == c.node && c.role == .item)
                        #expect(layout.cellIndex(for: n) == i)
                    case .merged(let g): #expect(g.cell == i && c.role == .merged && g.folder == c.node)
                    default: break
                    }
                }
                // the same in points
                let p = CGPoint(x: (Double(c.rect.x) + 0.5) / scale, y: (Double(c.rect.y) + 0.5) / scale)
                #expect(layout.hitTest(point: p)?.cell == i)
            }
            #expect(layout.hitTest(pixelX: -1, y: 0) == nil)
            #expect(layout.hitTest(pixelX: w, y: 0) == nil)
        }
    }
}

@Test func nodesInsideMergedFoldersMapToTheMergedCell() throws {
    // a folder of 2000 small subfolders (each under 16 px) next to one huge file
    var tinyFolders: [FixtureItem] = []
    for i in 0 ..< 2000 { tinyFolders.append(.folder("t\(i)", [.file("x", size: 1000, kind: "A"), .file("y", size: 500, kind: "B")])) }
    let s = SnapshotBuilder.build(.folder("root", [.file("huge", size: 10_000_000, kind: "C"), .folder("many", tinyFolders)]))
    let layout = TreemapModel(snapshot: s).layout(pixelWidth: 400, pixelHeight: 300)
    let deep = (0 ..< s.nodeCount).first { s.name(of: $0) == "y" }!
    let cell = try #require(layout.cellIndex(for: deep))
    #expect(layout.cell(cell).role == .merged)
    #expect(layout.rect(for: deep) == layout.cell(cell).rect)
}

// MARK: - robustness

@Test func zeroSizesAndBadSumsDoNotCrash() {
    let cases: [FixtureItem] = [
        .folder("root", []),
        .folder("root", [.file("a", size: 0, kind: "A"), .file("b", size: 0, kind: "A")]),
        .folder("root", [.folder("z", [.file("a", size: 0, kind: "A")]), .folder("e", [])]),
        .folder("root", [.file("a", size: 100, kind: "A")] + (0 ..< 50).map { .file("z\($0)", size: 0, kind: "B") }),
    ]
    for item in cases {
        let s = SnapshotBuilder.build(item)
        for mode in [SizeMode.allocated, .logical] {
            let model = TreemapModel(snapshot: s, sizeMode: mode)
            for (w, h) in [(0, 0), (1, 1), (3, 200), (640, 480)] {
                let layout = model.layout(pixelWidth: w, pixelHeight: h)
                _ = layout.render()
                _ = layout.hitTest(pixelX: 0, y: 0)
                if w > 0 && h > 0 { checkTiling(layout) }
            }
        }
    }
    // children that don't sum to their parent (an invalid snapshot) must not trap either
    var bad = SnapshotBuilder.build(.folder("root", [.file("a", size: 10, kind: "A"), .file("b", size: 5, kind: "A")]))
    bad.allocatedSize[0] = 3
    bad.allocatedSize[2] = 1_000
    _ = TreemapModel(snapshot: bad).layout(pixelWidth: 300, pixelHeight: 200).render()
}

@Test func deepNestingDoesNotOverflowTheStack() {
    // a chain of 100,000 nested folders ending in one file, built directly as arrays
    let n = 100_001
    var flags = [NodeFlags](repeating: .directory, count: n)
    flags[n - 1] = []
    let s = Snapshot(rootPath: "/deep", scanDate: Date(timeIntervalSince1970: 0), volume: nil,
                     parent: (0 ..< n).map { UInt32(max(0, $0 - 1)) },
                     firstChild: (0 ..< n).map { $0 < n - 1 ? UInt32($0 + 1) : 0 },
                     childCount: (0 ..< n).map { $0 < n - 1 ? 1 : 0 },
                     allocatedSize: [UInt64](repeating: 4096, count: n), logicalSize: [UInt64](repeating: 4096, count: n),
                     nameOffset: [UInt32](repeating: 0, count: n), nameLength: [UInt16](repeating: 1, count: n),
                     kindIndex: (0 ..< n).map { $0 < n - 1 ? 0 : 1 }, flags: flags, nameBytes: Array("d".utf8),
                     kinds: [FileKind(identifier: "public.folder", name: "Folder"), FileKind(identifier: "", name: "A")])
    #expect(s.validate() == nil)
    let layout = TreemapModel(snapshot: s).layout(pixelWidth: 200, pixelHeight: 100)
    #expect(layout.cellCount == n)
    #expect(layout.cellIndex(for: n - 1) == n - 1)
    _ = layout.render()
}

// MARK: - cloud placeholders

@Test func cloudPlaceholdersAppearOnlyInLogicalMode() throws {
    let s = SnapshotBuilder.build(.folder("root", [
        .file("local", size: 4_000_000, kind: "A"),
        .file("cloud1", size: 0, logical: 6_000_000, kind: "A", flags: [.cloudPlaceholder]),
        .file("cloud2", size: 0, logical: 3_000_000, kind: "B", flags: [.cloudPlaceholder]),
    ]))
    let cloud1 = (0 ..< s.nodeCount).first { s.name(of: $0) == "cloud1" }!
    let local = (0 ..< s.nodeCount).first { s.name(of: $0) == "local" }!

    let allocated = TreemapModel(snapshot: s).layout(pixelWidth: 400, pixelHeight: 300)
    #expect(allocated.rect(for: cloud1) == nil)                         // ~0 bytes on disk: no cell
    #expect(allocated.rect(for: local)?.area == 400 * 300)

    let logical = TreemapModel(snapshot: s, sizeMode: .logical).layout(pixelWidth: 400, pixelHeight: 300)
    let cell = try #require(logical.cellIndex(for: cloud1))
    #expect(logical.cell(cell).rect.area > 400 * 300 * 4 / 10)          // 6 of 13 MB by length
    let kindColor = logical.model.kindColors.color(forKind: Int(s.kindIndex[cloud1]))
    #expect(logical.color(ofCell: cell) == CloudStyle.color(kindColor))  // drawn washed out
    #expect(logical.color(ofCell: logical.cellIndex(for: local)!) == logical.model.kindColors.color(forKind: Int(s.kindIndex[local])))
    // and the washed-out cushion is lighter but still shaded
    let bitmap = logical.render()
    let r = logical.cell(cell).rect
    let center = bitmap.pixel(x: r.x + r.width / 3, y: r.y + r.height / 3), corner = bitmap.pixel(x: r.maxX - 1, y: r.maxY - 1)
    #expect(Int(center.r) + Int(center.g) + Int(center.b) > Int(corner.r) + Int(corner.g) + Int(corner.b))
}

// MARK: - zoom, retina, selection, rendering

@Test func zoomLaysOutASubtreeAsTheRoot() {
    let s = fixtures[0]
    let model = TreemapModel(snapshot: s)
    let sub = s.children(of: 0).first { s.isDirectory($0) && s.childCount[$0] > 3 }!
    let layout = model.layout(root: sub, pixelWidth: 500, pixelHeight: 400)
    #expect(layout.cell(0).node == sub)
    #expect(layout.rect(for: sub) == PixelRect(x: 0, y: 0, width: 500, height: 400))
    let outside = s.children(of: 0).first { $0 != sub }!
    #expect(layout.rect(for: outside) == nil)
    checkTiling(layout)
}

@Test func retinaLayoutIsInPixelsAndMergesByPoints() {
    let model = TreemapModel(snapshot: fixtures[1])
    let x1 = model.layout(pixelWidth: 720, pixelHeight: 450, scale: 1)
    let x2 = model.layout(pixelWidth: 1440, pixelHeight: 900, scale: 2)
    #expect(x2.cell(0).rect == PixelRect(x: 0, y: 0, width: 1440, height: 900))
    // the same items are merged at both scales (thresholds are in points), so cell counts are close
    #expect(abs(x1.drawnCells.count - x2.drawnCells.count) < x1.drawnCells.count / 10 + 5)
    for i in x1.drawnCells where x1.cell(i).role == .item && x1.cell(i).rect.area > 400 {
        let r1 = x1.cell(i).rect
        guard let r2 = x2.rect(for: x1.cell(i).node) else { Issue.record("missing at 2x"); continue }
        #expect(abs(r2.x - 2 * r1.x) <= 2 && abs(r2.width - 2 * r1.width) <= 3)
    }
    #expect(x2.pointRect(for: x1.cell(1).node) != nil)
}

@Test func selectionFrameIsYellowAndTwoPointsWide() {
    let layout = TreemapModel(snapshot: fixtures[0]).layout(pixelWidth: 600, pixelHeight: 400, scale: 2)
    let cell = layout.drawnCells.max { layout.cell($0).rect.area < layout.cell($1).rect.area }!
    let r = layout.cell(cell).rect
    let bitmap = layout.render(selection: cell)
    let inside = bitmap.pixel(x: r.x + r.width / 2, y: r.y + 1), beyond = bitmap.pixel(x: r.x + r.width / 2, y: r.y + 2)
    #expect(inside == (255, 255, 0))
    #expect(!(beyond == (255, 255, 0)))
}

@Test func renderingHasNoHolesAndIsDeterministic() {
    let model = TreemapModel(snapshot: SyntheticSnapshot.make(seed: 9))
    let layout = model.layout(pixelWidth: 900, pixelHeight: 600, scale: 1)
    let a = layout.render(), b = layout.render()
    #expect(a.pixels == b.pixels)
    var black = 0
    for i in stride(from: 0, to: a.pixels.count, by: 4) where a.pixels[i] == 0 && a.pixels[i + 1] == 0 && a.pixels[i + 2] == 0 { black += 1 }
    #expect(black == 0)
    #expect(a.makeCGImage()?.width == 900)
}
