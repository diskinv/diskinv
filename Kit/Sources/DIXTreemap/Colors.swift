//
//  Colors.swift
//  DIXTreemap
//
//  The original Disk Inventory X palette and its kind -> color assignment
//  (src/FileTypeColors.swift, src/TreeMapViewController.swift and
//  TMVCushionRenderer.normalize on origin/master).
//
//  The original builds each color as NSColor(calibratedRed:...), normalizes it
//  to a brightness (r + g + b) of 1.8 after converting it to sRGB, wraps the
//  result in a *calibrated* NSColor again, and the cushion renderer converts it
//  to sRGB a second time. The values below are exactly what comes out of that
//  chain (computed with AppKit; a test re-derives them), so the shading reads
//  the very same base colors as the original.
//
//  GPL v3
//

import DIXCore
import Foundation

/// An sRGB color with components in 0...1.
public struct TreemapColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 8-bit sRGB components, as the cushion renderer would write them for a flat area
    public var rgb8: (UInt8, UInt8, UInt8) {
        func c(_ v: Double) -> UInt8 { UInt8(max(0, min(1, v)) * 255) }
        return (c(red), c(green), c(blue))
    }
}

public enum TreemapPalette {
    /// The 12 kind colors, in assignment order (blue, red, green, cyan, magenta,
    /// yellow, then the light variants), as the cushion shader sees them.
    public static let kindColors: [TreemapColor] = [
        TreemapColor(red: 0.32636463642120361, green: 0.61908704042434692, blue: 1),
        TreemapColor(red: 1, green: 0.5940740704536438, blue: 0.35148119926452637),
        TreemapColor(red: 0.45011252164840698, green: 0.98130637407302856, blue: 0.47430139780044556),
        TreemapColor(red: 0, green: 0.90900033712387085, blue: 0.92371624708175659),
        TreemapColor(red: 0.84556776285171509, green: 0.32816144824028015, blue: 0.83708685636520386),
        TreemapColor(red: 0.92469197511672974, green: 0.90162938833236694, blue: 0),
        TreemapColor(red: 0.57647329568862915, green: 0.59660637378692627, blue: 0.821003258228302),
        TreemapColor(red: 0.82748061418533325, green: 0.58995193243026733, blue: 0.5762905478477478),
        TreemapColor(red: 0.56684839725494385, green: 0.81326955556869507, blue: 0.58422303199768066),
        TreemapColor(red: 0.50163227319717407, green: 0.7325710654258728, blue: 0.73955005407333374),
        TreemapColor(red: 0.73415756225585938, green: 0.53973597288131714, blue: 0.72996681928634644),
        TreemapColor(red: 0.73735505342483521, green: 0.72661709785461426, blue: 0.51434606313705444),
    ]

    /// Every grey the original hands out ends up here: normalizing any grey to a
    /// brightness of 1.8 gives (0.6, 0.6, 0.6) calibrated, whatever grey it started
    /// as. So kinds beyond the 12th, the "free space" cell (built as white) and the
    /// "other space" cell (built as 0.2 grey) all render in this same mid grey.
    public static let grey = TreemapColor(red: 0.66422688961029053, green: 0.66422688961029053,
                                          blue: 0.66422688961029053)

    /// color of kinds beyond the palette (and of nodes whose kind has no statistic)
    public static let overflowKind = grey
    /// free space cell, as the original draws it (see `grey`)
    public static let freeSpace = grey
    /// other space cell, as the original draws it (see `grey`)
    public static let otherSpace = grey

    /// The original's color normalization, applied to sRGB components: scale to a
    /// brightness (r + g + b) of 1.8, then push any component above 1 into the
    /// others. (The original also converts calibrated RGB to sRGB around this;
    /// the palette constants above already include that.)
    public static func normalize(red: Double, green: Double, blue: Double) -> TreemapColor {
        let sum = red + green + blue
        let f = sum != 0 ? baseBrightness / sum : 1
        var r = red * f, g = green * f, b = blue * f
        CushionMath.normalize(&r, &g, &b)
        return TreemapColor(red: r, green: g, blue: b)
    }

    static let baseBrightness = 1.8
}

/// Assigns the palette to kinds the way the original does: kinds sorted by the
/// total size of their files (descending; ties by name, numeric compare), the
/// first 12 get the palette, the rest grey. Only files count, plus packages
/// when package contents are not shown (they are then drawn as one cell).
public struct KindColors: Sendable {
    /// color per kind index (`snapshot.kinds`)
    public let colors: [TreemapColor]
    /// kind indexes sorted by total size, descending (the order colors were handed out)
    public let rankedKinds: [Int]
    /// total size per kind index, in the size mode the colors were assigned for
    public let kindSizes: [UInt64]
    /// per kind index: which color it got, 0..<12 = palette, 12 = grey
    let colorSlot: [UInt8]

    public init(snapshot: Snapshot, sizeMode: SizeMode = .allocated, showPackageContents: Bool = false) {
        let kindCount = snapshot.kinds.count
        var sizes = [UInt64](repeating: 0, count: kindCount)
        var present = [Bool](repeating: false, count: kindCount)
        let sizeArray = sizeMode == .allocated ? snapshot.allocatedSize : snapshot.logicalSize
        snapshot.flags.withUnsafeBufferPointer { flags in
            snapshot.kindIndex.withUnsafeBufferPointer { kinds in
                sizeArray.withUnsafeBufferPointer { size in
                    for node in 0 ..< flags.count {
                        let f = flags[node]
                        let isLeaf = !f.contains(.directory) || (f.contains(.package) && !showPackageContents)
                        guard isLeaf else { continue }
                        let k = Int(kinds[node])
                        guard k < kindCount else { continue }
                        sizes[k] &+= size[node]
                        present[k] = true
                    }
                }
            }
        }

        // the original keys its statistics and colors by kind *name*
        var byName: [String: (size: UInt64, kinds: [Int])] = [:]
        for k in 0 ..< kindCount where present[k] {
            let name = snapshot.kinds[k].name
            byName[name, default: (0, [])].size &+= sizes[k]
            byName[name, default: (0, [])].kinds.append(k)
        }
        let rankedNames = byName.keys.sorted { a, b in
            let sa = byName[a]!.size, sb = byName[b]!.size
            if sa != sb { return sa > sb }
            return a.compare(b, options: .numeric) == .orderedAscending
        }

        var colors = [TreemapColor](repeating: TreemapPalette.overflowKind, count: kindCount)
        var slots = [UInt8](repeating: UInt8(TreemapPalette.kindColors.count), count: kindCount)
        var ranked: [Int] = []
        for (rank, name) in rankedNames.enumerated() {
            let inPalette = rank < TreemapPalette.kindColors.count
            for k in byName[name]!.kinds {
                colors[k] = inPalette ? TreemapPalette.kindColors[rank] : TreemapPalette.overflowKind
                if inPalette { slots[k] = UInt8(rank) }
                ranked.append(k)
            }
        }
        self.colors = colors
        self.colorSlot = slots
        self.rankedKinds = ranked
        self.kindSizes = sizes
    }

    /// Of the kinds in `touched` (with their byte counts in `acc`), the one to
    /// color a mixed area with: first the COLOR covering most bytes (all kinds
    /// past the 12th share one grey, so many small grey kinds outweigh one
    /// blue kind), then the largest kind of that color. Clears `acc` for `touched`.
    func dominantKind(_ touched: [Int], _ acc: inout [UInt64], fallback: Int) -> Int {
        var slotBytes = [UInt64](repeating: 0, count: TreemapPalette.kindColors.count + 1)
        for k in touched { slotBytes[Int(k < colorSlot.count ? colorSlot[k] : 12)] &+= acc[k] }
        var bestSlot = -1
        var bestBytes: UInt64 = 0
        for (slot, bytes) in slotBytes.enumerated() where bytes > bestBytes { bestSlot = slot; bestBytes = bytes }
        var best = fallback
        var bestKindBytes: UInt64 = 0
        for k in touched {
            let slot = Int(k < colorSlot.count ? colorSlot[k] : 12)
            if slot == bestSlot && acc[k] > bestKindBytes { best = k; bestKindBytes = acc[k] }
            acc[k] = 0
        }
        return best
    }

    public func color(forKind kindIndex: Int) -> TreemapColor {
        kindIndex >= 0 && kindIndex < colors.count ? colors[kindIndex] : TreemapPalette.overflowKind
    }
}
