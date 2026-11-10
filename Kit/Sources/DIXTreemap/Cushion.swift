//
//  Cushion.swift
//  DIXTreemap
//
//  The original cushion shader (src/TreeMap/TMVCushionRenderer.swift on
//  origin/master), kept bit for bit: ambient 0.15, light (-1, -1, 10) with the
//  `Ly = lx / len` quirk, brightness scaled by 2.5 / BASE_BRIGHTNESS, the
//  clamp-and-redistribute color normalization, and truncation to 8 bits.
//
//  GPL v3
//

/// The cushion surface of one cell: the coefficients of the summed parabolic
/// ridges of the cell and all its ancestors, z = s0 x^2 + s2 x + s1 y^2 + s3 y.
/// (Same layout as the original's `_surface[4]`: [ax, ay, bx, by].)
public struct CushionSurface: Sendable, Hashable {
    public var s0: Double = 0
    public var s1: Double = 0
    public var s2: Double = 0
    public var s3: Double = 0

    public init() {}

    /// adds the ridge of a cell, like TMVCushionRenderer.addRidge(byHeightFactor:)
    mutating func addRidge(x0: Int, y0: Int, x1: Int, y1: Int, heightFactor: Float) {
        // the original computes 4 * heightFactor in Float, then widens
        let h4 = Double(Float(4) * heightFactor)
        let wf = h4 / Double(x1 - x0)
        s2 += wf * Double(x1 + x0)
        s0 -= wf
        let hf = h4 / Double(y1 - y0)
        s3 += hf * Double(y1 + y0)
        s1 -= hf
    }
}

enum CushionMath {
    static let maxRGB = 1.0
    static let ambient = 0.15                    // Ia
    static let intensity = 1 - ambient           // Is
    // light at (-1, -1, 10); the original computes Ly from lx (preserved)
    static let lightLength = (1.0 + 1.0 + 100.0).squareRoot()
    static let Lx = -1.0 / lightLength
    static let Ly = -1.0 / lightLength           // = lx / len, as in the original
    static let Lz = 10.0 / lightLength
    static let brightnessScale = 2.5 / TreemapPalette.baseBrightness
    /// height factor of the root's children; each level below multiplies by 0.9 (in Float)
    static let rootHeightFactor: Float = 0.5
    static let heightScale: Float = 0.9

    @inline(__always)
    static func normalize(_ red: inout Double, _ green: inout Double, _ blue: inout Double) {
        if red > maxRGB {
            distribute(&red, &green, &blue)
        } else if green > maxRGB {
            distribute(&green, &red, &blue)
        } else if blue > maxRGB {
            distribute(&blue, &red, &green)
        }
    }

    @inline(__always)
    static func distribute(_ first: inout Double, _ second: inout Double, _ third: inout Double) {
        var h = (first - maxRGB) / 2.0
        first = maxRGB
        second += h
        third += h
        if second > maxRGB {
            h = second - maxRGB
            second = maxRGB
            third += h
        } else if third > maxRGB {
            h = third - maxRGB
            third = maxRGB
            second += h
        }
    }

    @inline(__always)
    static func byte(_ v: Double) -> UInt8 {
        // the original writes UInt8(v * 255); clamp so a NaN or overshoot can never trap
        let s = v * 255
        return s >= 255 ? 255 : (s > 0 ? UInt8(s) : 0)
    }

    /// Shades rows y0..<y1, columns x0..<x1 of one cell into an RGBA8 buffer.
    /// `nx` holds the precomputed x-normals for columns x0..<x1 of this cell.
    @inline(__always)
    static func shade(into pixels: UnsafeMutablePointer<UInt8>, bytesPerRow: Int,
                      x0: Int, x1: Int, y0: Int, y1: Int,
                      surface s: CushionSurface, color: TreemapColor, nx: UnsafeMutablePointer<Double>) {
        let colR = color.red, colG = color.green, colB = color.blue
        for ix in x0 ..< x1 {
            nx[ix - x0] = -(2 * s.s0 * (Double(ix) + 0.5) + s.s2)
        }
        for iy in y0 ..< y1 {
            let ny = -(2 * s.s1 * (Double(iy) + 0.5) + s.s3)
            // same association as the original: (nx*Lx + ny*Ly) + Lz, (nx*nx + ny*ny) + 1
            let nyLy = ny * Ly
            let nyny = ny * ny
            var p = pixels + iy * bytesPerRow + x0 * 4
            for i in 0 ..< (x1 - x0) {
                let n = nx[i]
                let cosa = (n * Lx + nyLy + Lz) / (n * n + nyny + 1.0).squareRoot()
                var brightness = intensity * cosa
                brightness = brightness < 0 ? ambient : (brightness + ambient)
                brightness *= brightnessScale
                var red = colR * brightness
                var green = colG * brightness
                var blue = colB * brightness
                normalize(&red, &green, &blue)
                p[0] = byte(red)
                p[1] = byte(green)
                p[2] = byte(blue)
                p[3] = 255
                p += 4
            }
        }
    }
}
