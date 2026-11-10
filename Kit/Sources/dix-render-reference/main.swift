//
//  dix-render-reference
//
//  Renders a snapshot with the ORIGINAL Disk Inventory X treemap code
//  (Original/, vendored unchanged from origin/master src/TreeMap/), fed through
//  a data-source shim that mirrors TreeMapViewController + FileTypeColors.
//  This is the visual bar DIXTreemap is measured against.
//
//  dix-render-reference <snap.dixsnap | synthetic[:seed[:scale]]> -o out.png
//      [--size 1440x900] [--scale 2] [--root <path>] [--mode allocated|logical]
//      [--packages] [--free-space] [--other-space] [--cells cells.txt]
//
//  --size is in points; the bitmap is size x scale pixels. --cells writes one
//  line "x y w h" per leaf cell the original actually drew (in pixels).
//
//  GPL v3
//

import Cocoa
import DIXCore
import DIXTreemap

// MARK: - arguments

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i ... i + 1)
    return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let outPath = option("-o") ?? "reference.png"
let sizeArg = option("--size") ?? "1440x900"
let scale = Double(option("--scale") ?? "1") ?? 1
let rootArg = option("--root")
let mode: SizeMode = (option("--mode") ?? "allocated") == "logical" ? .logical : .allocated
let cellsPath = option("--cells")
let showPackageContents = flag("--packages")
let showFreeSpace = flag("--free-space")
let showOtherSpace = flag("--other-space")
guard let snapArg = args.first else {
    fail("usage: dix-render-reference <snap.dixsnap | synthetic[:seed[:scale]]> -o out.png [--size WxH] [--scale S] [--root path] [--mode allocated|logical]")
}
let dims = sizeArg.split(separator: "x").compactMap { Int($0) }
guard dims.count == 2, dims[0] > 0, dims[1] > 0 else { fail("bad --size \(sizeArg)") }
let pixelWidth = Int((Double(dims[0]) * scale).rounded()), pixelHeight = Int((Double(dims[1]) * scale).rounded())

func loadSnapshot(_ arg: String) -> Snapshot {
    if arg.hasPrefix("synthetic") {
        let parts = arg.split(separator: ":").dropFirst().compactMap { Int($0) }
        return SyntheticSnapshot.make(seed: UInt64(parts.first ?? 1), scale: parts.count > 1 ? parts[1] : 1)
    }
    do { return try Snapshot(contentsOf: URL(fileURLWithPath: arg)) } catch { fail("cannot load \(arg): \(error)") }
}

let snapshot = loadSnapshot(snapArg)
var zoomRoot = Snapshot.root
if let rootArg {
    // match by absolute path (or relative to the snapshot root)
    let target = rootArg.hasPrefix("/") ? rootArg : snapshot.rootPath + "/" + rootArg
    guard let found = (0 ..< snapshot.nodeCount).first(where: { snapshot.isDirectory($0) && snapshot.path(of: $0) == target })
    else { fail("no folder \(target) in snapshot") }
    zoomRoot = found
}

// MARK: - data source shim (TreeMapViewController + FileTypeColors)

let otherSpaceItem = -1, freeSpaceItem = -2

final class Shim: NSObject, TreeMapViewDataSource, TreeMapViewDelegate {
    let s: Snapshot
    let root: Int
    let sizes: [UInt64]
    var order: [Int: [Int]] = [:]
    var kindColor: [String: NSColor] = [:]
    let freeColor = TMVCushionRenderer.normalize(NSColor(calibratedWhite: 1, alpha: 1))
    let otherColor = TMVCushionRenderer.normalize(NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
    let predefined: [NSColor] = [
        NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1),
        NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1),
        NSColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1),
        NSColor(calibratedRed: 0, green: 1, blue: 1, alpha: 1),
        NSColor(calibratedRed: 1, green: 0, blue: 1, alpha: 1),
        NSColor(calibratedRed: 1, green: 1, blue: 0, alpha: 1),
        NSColor(calibratedRed: 0.58, green: 0.58, blue: 1, alpha: 1),
        NSColor(calibratedRed: 1, green: 0.58, blue: 0.58, alpha: 1),
        NSColor(calibratedRed: 0.58, green: 1, blue: 0.58, alpha: 1),
        NSColor(calibratedRed: 0.58, green: 1, blue: 1, alpha: 1),
        NSColor(calibratedRed: 1, green: 0.58, blue: 1, alpha: 1),
        NSColor(calibratedRed: 1, green: 1, blue: 0.58, alpha: 1),
    ].map { TMVCushionRenderer.normalize($0) }
    var freeSize: UInt64 = 0, otherSize: UInt64 = 0

    init(snapshot: Snapshot, root: Int) {
        s = snapshot
        self.root = root
        sizes = mode == .allocated ? snapshot.allocatedSize : snapshot.logicalSize
        super.init()
        if let v = snapshot.volume {
            freeSize = showFreeSpace ? v.availableCapacity : 0
            let used = v.totalCapacity &- min(v.availableCapacity, v.totalCapacity)
            otherSize = showOtherSpace ? (used > sizes[root] ? used - sizes[root] : 0) : 0
        }
        reserveColorsForLargestKinds()
    }

    // FileSystemDoc.reserveColorsForLargestKinds: kind statistics over the
    // leaves, sorted by size descending (ties: name, numeric), colors handed out in that order
    func reserveColorsForLargestKinds() {
        var stats: [String: UInt64] = [:]
        for node in 0 ..< s.nodeCount {
            let f = s.flags[node]
            let leaf = !f.contains(.directory) || (f.contains(.package) && !showPackageContents)
            if !leaf { continue }
            let name = s.kind(of: node).name
            if name.isEmpty { continue }
            stats[name, default: 0] &+= sizes[node]
        }
        let ranked = stats.keys.sorted { a, b in
            stats[a]! != stats[b]! ? stats[a]! > stats[b]! : a.compare(b, options: .numeric) == .orderedAscending
        }
        for k in ranked { _ = color(forKind: k) }
    }

    // FileTypeColors.color(forKind:)
    func color(forKind kind: String) -> NSColor {
        if let c = kindColor[kind] { return c }
        let c: NSColor
        if predefined.count > kindColor.count {
            c = predefined[kindColor.count]
        } else {
            let g = min(0.9, CGFloat(kindColor.count) * 0.05)
            c = TMVCushionRenderer.normalize(NSColor(calibratedRed: g, green: g, blue: g, alpha: 1))
        }
        kindColor[kind] = c
        return c
    }

    func node(_ item: Any?) -> Int { (item as? Int) ?? root }

    func children(_ n: Int) -> [Int] {
        if let o = order[n] { return o }
        let first = Int(s.firstChild[n])
        var kids = Array(first ..< first + Int(s.childCount[n]))
        if mode == .logical {
            kids.sort { a, b in sizes[a] != sizes[b] ? sizes[a] > sizes[b] : a < b }
        }
        order[n] = kids
        return kids
    }

    func treeMapView(_ view: TreeMapView?, child index: UInt, ofItem item: Any?) -> Any? {
        let n = node(item)
        let kids = children(n)
        if n == root && Int(index) >= kids.count {
            if Int(index) - kids.count == 0 { return showOtherSpace ? otherSpaceItem : freeSpaceItem }
            return freeSpaceItem
        }
        return kids[Int(index)]
    }

    func treeMapView(_ view: TreeMapView?, isNode item: Any?) -> Bool {
        let n = node(item)
        if n < 0 { return false }
        if n == root { return s.isDirectory(n) }
        let f = s.flags[n]
        return f.contains(.directory) && (showPackageContents || !f.contains(.package))
    }

    func treeMapView(_ view: TreeMapView?, numberOfChildrenOfItem item: Any?) -> UInt32 {
        let n = node(item)
        if n < 0 { return 0 }
        var count = UInt32(s.childCount[n])
        if n == root && s.volume != nil {
            if showFreeSpace { count += 1 }
            if showOtherSpace { count += 1 }
        }
        return count
    }

    func treeMapView(_ view: TreeMapView?, weightByItem item: Any?) -> UInt64 {
        let n = node(item)
        if n == otherSpaceItem { return otherSize }
        if n == freeSpaceItem { return freeSize }
        var size = sizes[n]
        if n == root { size += freeSize + otherSize }
        return size
    }

    func treeMapView(_ view: TreeMapView?, willDisplayItem item: Any?, withRenderer renderer: TMVItem?) {
        let n = node(item)
        let c: NSColor
        if n == freeSpaceItem { c = freeColor } else if n == otherSpaceItem { c = otherColor } else { c = color(forKind: s.kind(of: n).name) }
        renderer?.setCushionColor(c)
    }
}

// MARK: - render

let t0 = Date()
let shim = Shim(snapshot: snapshot, root: zoomRoot)
let view = TreeMapView(frame: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
if scale != 1 {
    // Without a window the view's backing scale is 1. Scaling its bounds makes
    // convertToBacking / convertFromBacking scale by `scale`, so the original's
    // point-based checks ("cells under 1 pt are skipped") behave as on Retina.
    view.setBoundsSize(NSSize(width: Double(pixelWidth) / scale, height: Double(pixelHeight) / scale))
}
let item = TMVItem(dataSource: shim, delegate: shim, renderedItem: nil, treeMapView: view)
let t1 = Date()
item.calcLayout(NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
let t2 = Date()
guard let bmp = NSBitmapImageRep(rgbBitmapWithWidth: pixelWidth, height: pixelHeight) else { fail("bitmap") }
item.drawCushion(inBitmap: bmp)
let t3 = Date()

// copy into an RGBA bitmap and write it with the same PNG writer as dix-render
var out = TreemapBitmap(width: pixelWidth, height: pixelHeight)
let src = bmp.bitmapData!
let bpr = bmp.bytesPerRow
for y in 0 ..< pixelHeight {
    for x in 0 ..< pixelWidth {
        let p = src + y * bpr + x * 3
        let o = (y * pixelWidth + x) * 4
        out.pixels[o] = p[0]; out.pixels[o + 1] = p[1]; out.pixels[o + 2] = p[2]; out.pixels[o + 3] = 255
    }
}
do { try out.writePNG(to: URL(fileURLWithPath: outPath)) } catch { fail("cannot write \(outPath): \(error)") }

// the leaf cells the original drew (it skips anything under 1 pt, and its subtree)
var drawn = 0
if let cellsPath {
    var lines: [String] = []
    func visit(_ it: TMVItem) {
        let r = it.rect()
        let pts = view.convertRectFromBackingRespectingFlipped(r)
        if pts.width < 1 || pts.height < 1 { return }
        if it.isLeaf() {
            lines.append("\(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height))")
            return
        }
        for i in 0 ..< it.childCount() { if let c = it.child(at: UInt(i)) { visit(c) } }
    }
    visit(item)
    drawn = lines.count
    do { try (lines.joined(separator: "\n") + "\n").write(toFile: cellsPath, atomically: true, encoding: .utf8) } catch { fail("cannot write \(cellsPath)") }
}

let ms = { (a: Date, b: Date) in String(format: "%.0f ms", b.timeIntervalSince(a) * 1000) }
print("reference: \(snapshot.nodeCount) nodes, \(pixelWidth)x\(pixelHeight) px, renderers \(ms(t0, t1)), layout \(ms(t1, t2)), render \(ms(t2, t3))" + (cellsPath != nil ? ", \(drawn) leaf cells drawn" : ""))
