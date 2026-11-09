//
//  dix-render
//
//  Renders a snapshot with DIXTreemap, to iterate on the visuals offline.
//
//  dix-render <snap.dixsnap | synthetic[:seed[:scale]]> -o out.png
//      [--size 1440x900] [--scale 2] [--root <path>] [--select <path>]
//      [--mode allocated|logical] [--min-cell-area 16]
//      [--merged solid|texture|kinds|kinds-texture] [--pitch 3] [--relief 1]
//      [--packages] [--free-space] [--other-space]
//      [--compare]            also run dix-render-reference on the same input; write
//                             out-compare.png (reference | new), out-diff.png, and
//                             agreement stats where the reference drew cells >= 8x8 px
//      [--crop x,y,w,h] [--magnify 4]   also write out-crop.png (nearest neighbor)
//      [--repeat N]           time layout + render N times, report the best
//      [--ls]                 list the root's children with sizes and exit
//      [--hover x,y]          print what is under pixel x,y (with a merged area's breakdown)
//      [--montage out.png --styles solid,texture,kinds,kinds-texture [--columns 2]
//       [--with-reference]]   one labeled image of several merged styles side by side
//                             (cropped and magnified when --crop is given), with timings
//
//  GPL v3
//

import CoreGraphics
import CoreText
import DIXCore
import DIXTreemap
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i ... i + 1)
    return v
}
@MainActor func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let outPath = option("-o") ?? "treemap.png"
let sizeArg = option("--size") ?? "1440x900"
let scaleArg = option("--scale") ?? "1"
let scale = Double(scaleArg) ?? 1
let rootArg = option("--root")
let selectArg = option("--select")
let modeArg = option("--mode") ?? "allocated"
let mode: SizeMode = modeArg == "logical" ? .logical : .allocated
let minArea = Double(option("--min-cell-area") ?? "16") ?? 16
@MainActor func parseStyle(_ name: String) -> MergedCellStyle {
    if name == "cushion" { return .solid }
    guard let style = MergedCellStyle(rawValue: name) else {
        fail("unknown merged style \(name); use one of \(MergedCellStyle.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    return style
}
let mergedStyle = parseStyle(option("--merged") ?? TreemapOptions().mergedCellStyle.rawValue)
let pitch = Double(option("--pitch") ?? "3") ?? 3
let relief = Float(option("--relief") ?? "1") ?? 1
let hoverArg = option("--hover")
let montagePath = option("--montage")
let montageStyles = (option("--styles") ?? "solid,texture,kinds,kinds-texture").split(separator: ",").map { parseStyle(String($0)) }
let montageColumns = max(1, Int(option("--columns") ?? "2") ?? 2)
let withReference = flag("--with-reference")
let cropArg = option("--crop")
let magnify = Int(option("--magnify") ?? "4") ?? 4
let repeatCount = max(1, Int(option("--repeat") ?? "1") ?? 1)
let showPackageContents = flag("--packages")
let showFreeSpace = flag("--free-space")
let showOtherSpace = flag("--other-space")
let compare = flag("--compare")
let listChildren = flag("--ls")
let originalRounding = flag("--original-rounding")
guard let snapArg = args.first else {
    fail("usage: dix-render <snap.dixsnap | synthetic[:seed[:scale]]> -o out.png [--size WxH] [--scale S] [--root path] [--select path] [--mode allocated|logical] [--min-cell-area 16] [--compare]")
}
let dims = sizeArg.split(separator: "x").compactMap { Int($0) }
guard dims.count == 2, dims[0] > 0, dims[1] > 0 else { fail("bad --size \(sizeArg)") }
let pixelWidth = Int((Double(dims[0]) * scale).rounded()), pixelHeight = Int((Double(dims[1]) * scale).rounded())

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
func fmt(_ ms: Double) -> String { String(format: "%.1f ms", ms) }

// MARK: - load

let tLoad = now()
let snapshot: Snapshot
if snapArg.hasPrefix("synthetic") {
    let parts = snapArg.split(separator: ":").dropFirst().compactMap { Int($0) }
    snapshot = SyntheticSnapshot.make(seed: UInt64(parts.first ?? 1), scale: parts.count > 1 ? parts[1] : 1)
} else {
    do { snapshot = try Snapshot(contentsOf: URL(fileURLWithPath: snapArg)) } catch { fail("cannot load \(snapArg): \(error)") }
}
let loadMs = now() - tLoad

@MainActor func findNode(_ path: String) -> NodeIndex {
    let target = path.hasPrefix("/") ? path : snapshot.rootPath + "/" + path
    guard let n = (0 ..< snapshot.nodeCount).first(where: { snapshot.path(of: $0) == target }) else {
        fail("no item \(target) in snapshot")
    }
    return n
}
let root = rootArg.map(findNode) ?? Snapshot.root
if listChildren {
    // list the (root's) children with their sizes, largest first, and stop
    for c in snapshot.children(of: root).prefix(40) {
        let mb = Double(snapshot.size(of: c, mode: mode)) / 1e6
        print(String(format: "%10.1f MB  %@%@", mb, snapshot.name(of: c), snapshot.isDirectory(c) ? "/" : ""))
    }
    exit(0)
}

// MARK: - layout + render

let tModel = now()
let model = TreemapModel(snapshot: snapshot, sizeMode: mode, showPackageContents: showPackageContents)
let modelMs = now() - tModel
let options = TreemapOptions(minimumCellArea: minArea, showFreeSpace: showFreeSpace,
                             showOtherSpace: showOtherSpace, mergedCellStyle: mergedStyle,
                             originalRounding: originalRounding, texturePitch: pitch, textureRelief: relief)

var layoutMs = Double.infinity, renderMs = Double.infinity, totalMs = Double.infinity
let tCold = now()
var layout = model.layout(root: root, pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale, options: options)
var bitmap = layout.render()
let coldMs = now() - tCold
for _ in 0 ..< repeatCount {
    let a = now()
    layout = model.layout(root: root, pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale, options: options)
    let b = now()
    bitmap = layout.render()
    let c = now()
    layoutMs = min(layoutMs, b - a)
    renderMs = min(renderMs, c - b)
    totalMs = min(totalMs, c - a)
}
if let selectArg {
    let node = findNode(selectArg)
    if let cell = layout.cellIndex(for: node) {
        layout.drawSelectionFrame(cell: cell, into: &bitmap)
        print("selected \(selectArg): cell \(layout.cell(cell).rect)")
    } else {
        print("note: \(selectArg) has no cell in this layout")
    }
}
do { try bitmap.writePNG(to: URL(fileURLWithPath: outPath)) } catch { fail("cannot write \(outPath): \(error)") }

let drawn = layout.drawnCells.count
print("\(snapshot.nodeCount) nodes, \(pixelWidth)x\(pixelHeight) px (scale \(scaleArg)), \(mode.rawValue), \(layout.cellCount) cells (\(drawn) drawn, \(layout.mergedGroups.count) merged)")
print("load \(fmt(loadMs)), model \(fmt(modelMs)), first layout+render \(fmt(coldMs)), layout \(fmt(layoutMs)), render \(fmt(renderMs)), layout+render \(fmt(totalMs))" + (repeatCount > 1 ? " (best of \(repeatCount))" : ""))

let base = outPath.hasSuffix(".png") ? String(outPath.dropLast(4)) : outPath

func crop(_ b: TreemapBitmap, _ x: Int, _ y: Int, _ w: Int, _ h: Int, magnify m: Int) -> TreemapBitmap {
    var out = TreemapBitmap(width: w * m, height: h * m)
    for oy in 0 ..< h * m {
        for ox in 0 ..< w * m {
            let sx = x + ox / m, sy = y + oy / m
            guard sx >= 0, sy >= 0, sx < b.width, sy < b.height else { continue }
            let si = (sy * b.width + sx) * 4, oi = (oy * out.width + ox) * 4
            out.pixels[oi] = b.pixels[si]; out.pixels[oi + 1] = b.pixels[si + 1]; out.pixels[oi + 2] = b.pixels[si + 2]
        }
    }
    return out
}

let cropRect: [Int]? = cropArg.map { $0.split(separator: ",").compactMap { Int($0) } }
if let c = cropRect, c.count == 4 {
    try? crop(bitmap, c[0], c[1], c[2], c[3], magnify: magnify).writePNG(to: URL(fileURLWithPath: base + "-crop.png"))
}

if let hoverArg {
    let v = hoverArg.split(separator: ",").compactMap { Int($0) }
    if v.count == 2, let hit = layout.hitTest(pixelX: v[0], y: v[1]) {
        switch hit {
        case .node(let n, _): print("hover: \(snapshot.path(of: n)) (\(snapshot.kind(of: n).name), \(model.size(of: n)) bytes)")
        case .merged(let g, _):
            let b = layout.breakdown(atPixelX: v[0], y: v[1]) ?? layout.breakdown(of: g)
            print("hover: in \(snapshot.path(of: g.folder)): \(b.summary())")
        case .freeSpace: print("hover: free space")
        case .otherSpace: print("hover: other space")
        }
    }
}

// MARK: - montage of merged styles

/// runs dix-render-reference with this run's arguments and reads its PNG back
@MainActor func renderReference(to png: String, cells: String? = nil) -> TreemapBitmap {
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let tool = me.deletingLastPathComponent().appendingPathComponent("dix-render-reference")
    var refArgs = [snapArg, "-o", png, "--size", sizeArg, "--scale", scaleArg, "--mode", modeArg]
    if let cells { refArgs += ["--cells", cells] }
    if let rootArg { refArgs += ["--root", rootArg] }
    if showPackageContents { refArgs.append("--packages") }
    if showFreeSpace { refArgs.append("--free-space") }
    if showOtherSpace { refArgs.append("--other-space") }
    let proc = Process()
    proc.executableURL = tool
    proc.arguments = refArgs
    proc.standardOutput = FileHandle.nullDevice
    do { try proc.run() } catch { fail("cannot run \(tool.path): \(error)") }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0, let ref = try? TreemapBitmap(contentsOfPNG: URL(fileURLWithPath: png)) else {
        fail("reference renderer failed")
    }
    return ref
}

/// lays out labeled panels in a grid on white, labels in a band above each panel.
/// Panel pixels are copied as they are (no color management); only the labels
/// are drawn with CoreText.
func montage(_ panels: [(String, TreemapBitmap)], columns: Int) -> TreemapBitmap? {
    guard let first = panels.first?.1 else { return nil }
    let pw = first.width, ph = first.height
    let gap = 12, band = 34
    let cols = min(columns, panels.count), rows = (panels.count + cols - 1) / cols
    let w = cols * pw + (cols + 1) * gap, h = rows * (ph + band) + (rows + 1) * gap
    var canvas = TreemapBitmap(width: w, height: h)
    canvas.fill(PixelRect(x: 0, y: 0, width: w, height: h), r: 255, g: 255, b: 255)
    var labels: [(String, Int, Int)] = []
    for (i, (label, bitmap)) in panels.enumerated() {
        let x = gap + (i % cols) * (pw + gap)
        let top = gap + (i / cols) * (ph + band + gap)
        for y in 0 ..< min(ph, bitmap.height) {
            let src = y * bitmap.width * 4, dst = ((top + band + y) * w + x) * 4
            let n = min(pw, bitmap.width) * 4
            canvas.pixels.replaceSubrange(dst ..< dst + n, with: bitmap.pixels[src ..< src + n])
        }
        labels.append((label, x, top))
    }
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 22, nil)
    canvas.pixels.withUnsafeMutableBytes { buf in
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        let attrs = [kCTFontAttributeName: font,
                     kCTForegroundColorAttributeName: CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)] as CFDictionary
        for (label, x, top) in labels {
            guard let text = CFAttributedStringCreate(nil, label as CFString, attrs) else { continue }
            ctx.textPosition = CGPoint(x: x + 2, y: h - top - band + 9)
            CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        }
    }
    return canvas
}

if let montagePath {
    var panels: [(String, TreemapBitmap)] = []
    let c = cropRect.flatMap { $0.count == 4 ? $0 : nil }
    func framed(_ b: TreemapBitmap) -> TreemapBitmap { c.map { crop(b, $0[0], $0[1], $0[2], $0[3], magnify: magnify) } ?? b }
    if withReference {
        panels.append(("original (reference)", framed(renderReference(to: base + "-montage-ref.png"))))
    }
    let letters = ["solid": "A", "texture": "B", "kinds": "C", "kinds-texture": "D"]
    for style in montageStyles {
        var o = options
        o.mergedCellStyle = style
        let styleModel = TreemapModel(snapshot: snapshot, sizeMode: mode, showPackageContents: showPackageContents)
        let a = now()
        let cold = styleModel.layout(root: root, pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale, options: o)
        let coldBitmap = cold.render()
        let b = now()
        var best = Double.infinity
        for _ in 0 ..< repeatCount {
            let t = now()
            _ = styleModel.layout(root: root, pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale, options: o).render()
            best = min(best, now() - t)
        }
        print(String(format: "  %@ %-14@ first layout+render %6.1f ms, warm %6.1f ms, %d drawn cells",
                     letters[style.rawValue] ?? "?", style.rawValue, b - a, best, cold.drawnCells.count))
        panels.append(("\(letters[style.rawValue] ?? "") \(style.rawValue)", framed(coldBitmap)))
    }
    guard let out = montage(panels, columns: montageColumns) else { fail("cannot compose montage") }
    do { try out.writePNG(to: URL(fileURLWithPath: montagePath)) } catch { fail("cannot write \(montagePath)") }
    print("wrote \(montagePath)")
}

// MARK: - compare against the original renderer

guard compare else { exit(0) }

let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let refTool = me.deletingLastPathComponent().appendingPathComponent("dix-render-reference")
let refPNG = base + "-ref.png", refCells = base + "-ref.cells"
var refArgs = [snapArg, "-o", refPNG, "--size", sizeArg, "--scale", scaleArg, "--mode", modeArg, "--cells", refCells]
if let rootArg { refArgs += ["--root", rootArg] }
if showPackageContents { refArgs.append("--packages") }
if showFreeSpace { refArgs.append("--free-space") }
if showOtherSpace { refArgs.append("--other-space") }
let proc = Process()
proc.executableURL = refTool
proc.arguments = refArgs
do { try proc.run() } catch { fail("cannot run \(refTool.path): \(error)") }
proc.waitUntilExit()
guard proc.terminationStatus == 0 else { fail("reference renderer failed") }

let ref: TreemapBitmap
do { ref = try TreemapBitmap(contentsOfPNG: URL(fileURLWithPath: refPNG)) } catch { fail("cannot read \(refPNG)") }
guard ref.width == bitmap.width, ref.height == bitmap.height else { fail("size mismatch") }

// masks: pixels inside reference leaf cells of at least 8x8 px; "interior" = inset by 2 px
let w = pixelWidth, h = pixelHeight
var bigMask = [Bool](repeating: false, count: w * h)
var interiorMask = [Bool](repeating: false, count: w * h)
var refCellCount = 0, bigCellCount = 0
if let text = try? String(contentsOfFile: refCells, encoding: .utf8) {
    for line in text.split(separator: "\n") {
        let v = line.split(separator: " ").compactMap { Int($0) }
        guard v.count == 4 else { continue }
        refCellCount += 1
        guard v[2] >= 8, v[3] >= 8 else { continue }
        bigCellCount += 1
        for y in max(0, v[1]) ..< min(h, v[1] + v[3]) {
            for x in max(0, v[0]) ..< min(w, v[0] + v[2]) {
                bigMask[y * w + x] = true
                if x >= v[0] + 2 && x < v[0] + v[2] - 2 && y >= v[1] + 2 && y < v[1] + v[3] - 2 {
                    interiorMask[y * w + x] = true
                }
            }
        }
    }
}

struct Stats {
    var n = 0, exact = 0, close = 0
    var absSum = 0.0
    mutating func add(_ d: (Int, Int, Int)) {
        n += 1
        let m = max(d.0, d.1, d.2)
        if m == 0 { exact += 1 }
        if m <= 8 { close += 1 }
        absSum += Double(d.0 + d.1 + d.2) / 3
    }
    func line(_ name: String) -> String {
        guard n > 0 else { return "\(name): no pixels" }
        return String(format: "%@: %.2f%% identical, %.2f%% within 8 levels, mean error %.2f levels (%d px)",
                      name, 100 * Double(exact) / Double(n), 100 * Double(close) / Double(n), absSum / Double(n), n)
    }
}
var big = Stats(), interior = Stats(), all = Stats()
var diff = TreemapBitmap(width: w, height: h)
for i in 0 ..< w * h {
    let o = i * 4
    let d = (abs(Int(ref.pixels[o]) - Int(bitmap.pixels[o])), abs(Int(ref.pixels[o + 1]) - Int(bitmap.pixels[o + 1])),
             abs(Int(ref.pixels[o + 2]) - Int(bitmap.pixels[o + 2])))
    all.add(d)
    if bigMask[i] { big.add(d) }
    if interiorMask[i] { interior.add(d) }
    // diff image: grey copy of the reference, differences in red (brighter = bigger)
    let m = max(d.0, d.1, d.2)
    let g = UInt8((Int(ref.pixels[o]) + Int(ref.pixels[o + 1]) + Int(ref.pixels[o + 2])) / 12)
    if m == 0 {
        diff.pixels[o] = g; diff.pixels[o + 1] = g; diff.pixels[o + 2] = g
    } else {
        diff.pixels[o] = UInt8(min(255, 96 + m * 4)); diff.pixels[o + 1] = g / 2; diff.pixels[o + 2] = g / 2
    }
}
try? diff.writePNG(to: URL(fileURLWithPath: base + "-diff.png"))

// side by side: reference | new, separated by a 16 px white gutter
let gutter = 16
var side = TreemapBitmap(width: w * 2 + gutter, height: h)
side.fill(PixelRect(x: 0, y: 0, width: side.width, height: h), r: 255, g: 255, b: 255)
for y in 0 ..< h {
    for x in 0 ..< w {
        let s = (y * w + x) * 4
        for (dx, src) in [(0, ref), (w + gutter, bitmap)] {
            let o = (y * side.width + x + dx) * 4
            side.pixels[o] = src.pixels[s]; side.pixels[o + 1] = src.pixels[s + 1]; side.pixels[o + 2] = src.pixels[s + 2]
        }
    }
}
try? side.writePNG(to: URL(fileURLWithPath: base + "-compare.png"))
if let c = cropRect, c.count == 4 {
    try? crop(ref, c[0], c[1], c[2], c[3], magnify: magnify).writePNG(to: URL(fileURLWithPath: base + "-crop-ref.png"))
}

var black = 0
for i in 0 ..< w * h where ref.pixels[i * 4] == 0 && ref.pixels[i * 4 + 1] == 0 && ref.pixels[i * 4 + 2] == 0 { black += 1 }
var myBlack = 0
for i in 0 ..< w * h where bitmap.pixels[i * 4] == 0 && bitmap.pixels[i * 4 + 1] == 0 && bitmap.pixels[i * 4 + 2] == 0 { myBlack += 1 }

print("compare: reference drew \(refCellCount) leaf cells, \(bigCellCount) of them >= 8x8 px")
print(big.line("  cells >= 8x8     "))
print(interior.line("  their interiors  "))
print(all.line("  whole image      "))
print(String(format: "  black (hole) pixels: reference %.2f%%, new %.2f%%",
             100 * Double(black) / Double(w * h), 100 * Double(myBlack) / Double(w * h)))
print("wrote \(base)-compare.png, \(base)-diff.png, \(refPNG)")
