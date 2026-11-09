//
//  TreemapRenderer.swift
//  DIXTreemap
//
//  Shades a layout into an RGBA bitmap with the original cushion shader,
//  in parallel. Every drawn cell owns its pixels, so cells (or row bands of
//  big cells) can be shaded concurrently without locking.
//
//  GPL v3
//

import CoreGraphics
import DIXCore
import Foundation

/// An 8-bit RGBA bitmap (alpha always 255), rows top to bottom.
public struct TreemapBitmap: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]
    public var bytesPerRow: Int { width * 4 }

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        var p = [UInt8](repeating: 0, count: self.width * self.height * 4)
        // opaque black, like the original's freshly allocated bitmap
        for i in stride(from: 3, to: p.count, by: 4) { p[i] = 255 }
        self.pixels = p
    }

    public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }

    /// the bitmap as an sRGB CGImage
    public func makeCGImage() -> CGImage? {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// fills a rect (clipped) with a color
    public mutating func fill(_ rect: PixelRect, r: UInt8, g: UInt8, b: UInt8) {
        let xa = max(0, rect.x), xb = min(width, rect.maxX)
        let ya = max(0, rect.y), yb = min(height, rect.maxY)
        guard xa < xb, ya < yb else { return }
        for y in ya ..< yb {
            var i = (y * width + xa) * 4
            for _ in xa ..< xb {
                pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
                i += 4
            }
        }
    }
}

/// How cloud placeholders (logical mode) are drawn: "not on this disk".
public enum CloudStyle {
    /// Shades placeholder cells with a washed-out version of their color: the
    /// cushion keeps its shape and highlight, but at lower saturation and
    /// higher brightness, so it reads as present-but-elsewhere.
    static func color(_ c: TreemapColor) -> TreemapColor {
        let grey = (c.red + c.green + c.blue) / 3
        let keep = 0.3, mixGrey = 0.7
        let r = c.red * keep + grey * mixGrey
        let g = c.green * keep + grey * mixGrey
        let b = c.blue * keep + grey * mixGrey
        let lift = 0.14
        return TreemapColor(red: r + (1 - r) * lift, green: g + (1 - g) * lift, blue: b + (1 - b) * lift)
    }
}

extension TreemapLayout {
    /// the color a drawn cell is shaded with
    public func color(ofCell index: Int) -> TreemapColor {
        let c = cellData[index]
        var color: TreemapColor
        switch c.role {
        case .freeSpace: color = TreemapPalette.freeSpace
        case .otherSpace: color = TreemapPalette.otherSpace
        default:
            if c.colorSlot >= 0 {
                color = KindColors.color(ofSlot: Int(c.colorSlot))
            } else {
                color = c.colorKind >= 0 ? model.kindColors.color(forKind: Int(c.colorKind)) : TreemapPalette.overflowKind
            }
        }
        if c.cloud { color = CloudStyle.color(color) }
        return color
    }

    /// Renders the whole treemap. `selection` (a cell index) gets the yellow frame.
    public func render(selection: Int? = nil) -> TreemapBitmap {
        var bitmap = TreemapBitmap(width: pixelWidth, height: pixelHeight)
        render(into: &bitmap)
        if let selection { drawSelectionFrame(cell: selection, into: &bitmap) }
        return bitmap
    }

    /// Shades every drawn cell into `bitmap` (which must be pixelWidth x pixelHeight).
    public func render(into bitmap: inout TreemapBitmap) {
        precondition(bitmap.width == pixelWidth && bitmap.height == pixelHeight, "bitmap size must match the layout")
        guard pixelWidth > 0, pixelHeight > 0 else { return }

        // jobs: (cell, row range); big cells are cut into row bands
        struct Job { var cell: Int32; var y0: Int32; var y1: Int32 }
        var jobs: [Job] = []
        jobs.reserveCapacity(cellData.count + 64)
        var colors: [TreemapColor] = []
        colors.reserveCapacity(cellData.count)
        let bandPixels = 32 * 1024
        var totalPixels = 0
        for (i, c) in cellData.enumerated() {
            colors.append(c.childCount > 0 ? TreemapColor(red: 0, green: 0, blue: 0) : color(ofCell: i))
            guard c.childCount == 0 else { continue }
            let w = Int(c.x1 - c.x0), h = Int(c.y1 - c.y0)
            guard w > 0, h > 0 else { continue }
            totalPixels += w * h
            let rowsPerBand = max(1, bandPixels / w)
            var y = Int(c.y0)
            while y < Int(c.y1) {
                let y1 = min(Int(c.y1), y + rowsPerBand)
                jobs.append(Job(cell: Int32(i), y0: Int32(y), y1: Int32(y1)))
                y = y1
            }
        }

        // split the jobs into chunks of about equal pixel counts
        let threads = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunkCount = min(jobs.count, threads * 4)
        guard chunkCount > 0 else { return }
        var bounds: [Int] = [0]
        let perChunk = max(1, totalPixels / chunkCount)
        var acc = 0
        for (j, job) in jobs.enumerated() {
            let c = cellData[Int(job.cell)]
            acc += Int(c.x1 - c.x0) * Int(job.y1 - job.y0)
            if acc >= perChunk * bounds.count && bounds.count < chunkCount { bounds.append(j + 1) }
        }
        if bounds.last != jobs.count { bounds.append(jobs.count) }

        // Shared read-only inputs plus the output buffer; each job writes only
        // its own cell's pixels, so the concurrent writes never overlap.
        struct Shared: @unchecked Sendable {
            let cells: UnsafeBufferPointer<CellData>
            let jobs: UnsafeBufferPointer<Job>
            let colors: UnsafeBufferPointer<TreemapColor>
            let bounds: UnsafeBufferPointer<Int>
            let pixels: UnsafeMutablePointer<UInt8>
        }
        let width = pixelWidth
        let bytesPerRow = bitmap.bytesPerRow
        let chunkBounds = bounds
        cellData.withUnsafeBufferPointer { cells in
            jobs.withUnsafeBufferPointer { jobs in
                colors.withUnsafeBufferPointer { colors in
                    chunkBounds.withUnsafeBufferPointer { bounds in
                        bitmap.pixels.withUnsafeMutableBufferPointer { pixels in
                            let shared = Shared(cells: cells, jobs: jobs, colors: colors, bounds: bounds,
                                                pixels: pixels.baseAddress!)
                            DispatchQueue.concurrentPerform(iterations: bounds.count - 1) { chunk in
                                let nx = UnsafeMutablePointer<Double>.allocate(capacity: width)
                                defer { nx.deallocate() }
                                for j in shared.bounds[chunk] ..< shared.bounds[chunk + 1] {
                                    let job = shared.jobs[j]
                                    let c = shared.cells[Int(job.cell)]
                                    CushionMath.shade(into: shared.pixels, bytesPerRow: bytesPerRow,
                                                      x0: Int(c.x0), x1: Int(c.x1), y0: Int(job.y0), y1: Int(job.y1),
                                                      surface: c.surface, color: shared.colors[Int(job.cell)], nx: nx)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The original's selection frame: a yellow line 2 points wide, centered on
    /// the cell's edge (so 1 point outside, 1 point inside), clipped to the view.
    public func selectionFrameRects(cell index: Int) -> [PixelRect] {
        let r = cell(index).rect
        let s = max(1, Int(scale.rounded()))
        let outer = PixelRect(x: r.x - s, y: r.y - s, width: r.width + 2 * s, height: r.height + 2 * s)
        let edge = 2 * s
        return [
            PixelRect(x: outer.x, y: outer.y, width: outer.width, height: edge),
            PixelRect(x: outer.x, y: outer.maxY - edge, width: outer.width, height: edge),
            PixelRect(x: outer.x, y: outer.y, width: edge, height: outer.height),
            PixelRect(x: outer.maxX - edge, y: outer.y, width: edge, height: outer.height),
        ]
    }

    public func drawSelectionFrame(cell index: Int, into bitmap: inout TreemapBitmap) {
        guard index >= 0 && index < cellData.count else { return }
        for r in selectionFrameRects(cell: index) {
            bitmap.fill(r, r: 255, g: 255, b: 0)
        }
    }
}

extension KindColors {
    /// The kind list's color swatch, as the original draws it: one cushion
    /// (height factor 0.5) filling the swatch.
    public func swatch(forKind kindIndex: Int, pixelWidth: Int, pixelHeight: Int) -> TreemapBitmap {
        var bitmap = TreemapBitmap(width: pixelWidth, height: pixelHeight)
        guard pixelWidth > 0, pixelHeight > 0 else { return bitmap }
        var surface = CushionSurface()
        surface.addRidge(x0: 0, y0: 0, x1: pixelWidth, y1: pixelHeight, heightFactor: 0.5)
        let nx = UnsafeMutablePointer<Double>.allocate(capacity: pixelWidth)
        defer { nx.deallocate() }
        let bytesPerRow = bitmap.bytesPerRow
        bitmap.pixels.withUnsafeMutableBufferPointer { p in
            CushionMath.shade(into: p.baseAddress!, bytesPerRow: bytesPerRow, x0: 0, x1: pixelWidth,
                              y0: 0, y1: pixelHeight, surface: surface, color: color(forKind: kindIndex), nx: nx)
        }
        return bitmap
    }
}
