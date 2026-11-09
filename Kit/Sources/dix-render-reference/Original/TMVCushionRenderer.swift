//
//  TMVCushionRenderer.swift
//  Disk Inventory Xs
//
//  Swift port of TMVCushionRenderer.{h,m}. Owns the per-cell cushion
//  (Necker-cube) shading parameters and the per-pixel shader that writes into
//  an NSBitmapImageRep, plus color normalization to a fixed brightness.
//
//  The pixel loop is a verbatim translation of the ObjC shader: raw bitmapData
//  pointer arithmetic (3 bytes/pixel, bytesPerRow stride), all per-pixel math in
//  Double, the lx/len quirk for Ly, the 2.5/BASE_BRIGHTNESS scaling, and the
//  clamp/redistribute logic. Validated bit-for-bit against the ObjC build.
//
//  Selectors are pinned with @objc so the existing Swift consumers
//  (FileTypeColors, TreeMapViewController, the FileKinds controllers) and the
//  still-ObjC TMVItem keep working unchanged.
//
//  GPL v3
//

import Cocoa

// The treemap colors all have the "brightness" BASE_BRIGHTNESS.
// Brightness is a number from 0 to 3.0. RGB(0.5, 1, 0), for example, has a
// brightness of 2.5.
private let BASE_BRIGHTNESS: CGFloat = 1.8
private let MAX_RGB_VALUE: CGFloat = 1.0

@objc(TMVCushionRenderer)
final class TMVCushionRenderer: NSObject {

    private static let defaultCushionColor: NSColor =
        TMVCushionRenderer.normalize(NSColor(calibratedRed: 0, green: 0, blue: 0.9, alpha: 1))

    private var _rect: NSRect = .zero
    private var _color: NSColor

    // C array `CGFloat _surface[4]` -> a heap buffer so the raw-pointer
    // surface/setSurface: accessors can still vend a CGFloat* to the (still-ObjC)
    // TMVItem. Holds the quadratic ridge polynomial coefficients [ax, ay, bx, by].
    private let _surface = UnsafeMutablePointer<CGFloat>.allocate(capacity: 4)

    @objc
    override init() {
        _color = TMVCushionRenderer.defaultCushionColor
        _surface.initialize(repeating: 0, count: 4)
        _rect = .zero
        super.init()
    }

    @objc(initWithRect:)
    init(rect: NSRect) {
        _color = TMVCushionRenderer.defaultCushionColor
        _surface.initialize(repeating: 0, count: 4)
        _rect = rect
        super.init()
    }

    deinit {
        _surface.deinitialize(count: 4)
        _surface.deallocate()
    }

    @objc
    func rect() -> NSRect {
        _rect
    }

    @objc(setRect:)
    func setRect(_ rect: NSRect) {
        _rect = rect
    }

    @objc
    func color() -> NSColor {
        _color
    }

    @objc(setColor:)
    func setColor(_ newColor: NSColor) {
        // we need the color in the RGB color space
        var newColor = newColor
        if let rgbColor = newColor.usingColorSpace(.sRGB) {
            newColor = rgbColor
        }
        _color = newColor
    }

    @objc
    func surface() -> UnsafeMutablePointer<CGFloat> {
        _surface
    }

    @objc(setSurface:)
    func setSurface(_ newsurface: UnsafePointer<CGFloat>) {
        _surface.update(from: newsurface, count: 4)
    }

    @objc(addRidgeByHeightFactor:)
    func addRidge(byHeightFactor heightFactor: Float) {
        // Optimized (gains 15 ms of 1030):
        // ObjC computes `4 * heightFactor` in float (heightFactor is float, 4 is
        // int) then widens to CGFloat; replicate that float step for bit-fidelity.
        let h4: CGFloat = CGFloat(Float(4) * heightFactor)

        let wf: CGFloat = h4 / _rect.width
        _surface[2] += wf * (_rect.maxX + _rect.minX)
        _surface[0] -= wf

        let hf: CGFloat = h4 / _rect.height
        _surface[3] += hf * (_rect.maxY + _rect.minY)
        _surface[1] -= hf
    }

    @objc(renderCushionInBitmap:)
    func renderCushion(inBitmap bitmap: NSBitmapImageRep) {
        renderCushionInBitmapGeneric(bitmap)
    }

    @objc(renderCushionInBitmapGeneric:)
    func renderCushionInBitmapGeneric(_ bitmap: NSBitmapImageRep) {
        let rect = self.rect()
        let surface = self.surface()
        let baseColor = self.color()

        // we're expecting a bitmap which is at least as big as our rectangle,
        // has a 24 Bit color depth in RGB space (3 * 8 bytes) with no alpha channel
        assert(rect.maxY <= CGFloat(bitmap.pixelsHigh), "_rect exeeds bitmap height")
        assert(rect.maxX <= CGFloat(bitmap.pixelsWide), "_rect exeeds bitmap width")
        assert(bitmap.bitsPerSample == 8, "expecting bitmap to have 8 bits per RGB component")
        assert(!bitmap.hasAlpha, "not expecting the bitmap to have alpha component")

        // Cushion parameters
        let Ia = 0.15  // ambient light

        // where is the light:
        let lx = -1.0  // negative = left
        let ly = -1.0  // negative = top
        let lz = 10.0

        // Derived parameters
        let Is = 1 - Ia  // brightness

        let len = (lx * lx + ly * ly + lz * lz).squareRoot()
        let Lx = lx / len
        let Ly = lx / len   // BUG (preserved): uses lx, not ly
        let Lz = lz / len

        let colR = Double(baseColor.redComponent)
        let colG = Double(baseColor.greenComponent)
        let colB = Double(baseColor.blueComponent)

        guard let pixels = bitmap.bitmapData else { return }
        let bytesPerRow = bitmap.bytesPerRow

        let s0 = Double(surface[0])
        let s1 = Double(surface[1])
        let s2 = Double(surface[2])
        let s3 = Double(surface[3])

        let yStart = Int(rect.minY)
        let yEnd = Int(rect.maxY)
        let xStart = Int(rect.minX)
        let xEnd = Int(rect.maxX)

        var iy = yStart
        while iy < yEnd {
            let rowStart = pixels + iy * bytesPerRow
            let ny = -(2 * s1 * (Double(iy) + 0.5) + s3)

            var ix = xStart
            while ix < xEnd {
                let nx = -(2 * s0 * (Double(ix) + 0.5) + s2)

                let cosa = (nx * Lx + ny * Ly + Lz) / (nx * nx + ny * ny + 1.0).squareRoot()

                var brightness = Is * cosa
                brightness = brightness < 0 ? Ia : (brightness + Ia)

                assert(brightness <= 1.0, "brightness must be <=1")

                brightness *= 2.5 / Double(BASE_BRIGHTNESS)

                var red = CGFloat(colR * brightness)
                var green = CGFloat(colG * brightness)
                var blue = CGFloat(colB * brightness)

                TMVCushionRenderer.normalizeColorRed(&red, green: &green, blue: &blue)

                let pixel = rowStart + (ix * 3)
                pixel[0] = UInt8(red * 255)
                pixel[1] = UInt8(green * 255)
                pixel[2] = UInt8(blue * 255)

                ix += 1
            }
            iy += 1
        }
    }

    @objc(normalizeColorRed:green:blue:)
    static func normalizeColorRed(_ red: UnsafeMutablePointer<CGFloat>,
                                  green: UnsafeMutablePointer<CGFloat>,
                                  blue: UnsafeMutablePointer<CGFloat>) {
        // This eats 50% of function time
        if red.pointee > MAX_RGB_VALUE {
            distributeRGB1(red, toRGB2: green, toRGB3: blue)
        } else if green.pointee > MAX_RGB_VALUE {
            distributeRGB1(green, toRGB2: red, toRGB3: blue)
        } else if blue.pointee > MAX_RGB_VALUE {
            distributeRGB1(blue, toRGB2: red, toRGB3: green)
        }
    }

    @objc(normalizeColor:)
    static func normalize(_ color: NSColor) -> NSColor {
        // we need the color in the RGB color space
        var color = color
        if let rgbColor = color.usingColorSpace(.sRGB) {
            color = rgbColor
        }

        var red = color.redComponent
        var green = color.greenComponent
        var blue = color.blueComponent
        let alpha = color.alphaComponent

        let componentSum = red + green + blue
        let f: CGFloat = (componentSum != 0.0) ? (BASE_BRIGHTNESS / componentSum) : 1
        red *= f
        green *= f
        blue *= f

        normalizeColorRed(&red, green: &green, blue: &blue)

        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }

    // MARK: - Private

    private static func distributeRGB1(_ first: UnsafeMutablePointer<CGFloat>,
                                       toRGB2 second: UnsafeMutablePointer<CGFloat>,
                                       toRGB3 third: UnsafeMutablePointer<CGFloat>) {
        var h: CGFloat = (first.pointee - MAX_RGB_VALUE) / 2.0
        first.pointee = MAX_RGB_VALUE
        second.pointee += h
        third.pointee += h

        if second.pointee > MAX_RGB_VALUE {
            h = second.pointee - MAX_RGB_VALUE
            second.pointee = MAX_RGB_VALUE
            third.pointee += h
            assert(third.pointee <= MAX_RGB_VALUE, "color error")
        } else if third.pointee > MAX_RGB_VALUE {
            h = third.pointee - MAX_RGB_VALUE
            third.pointee = MAX_RGB_VALUE
            second.pointee += h
            assert(second.pointee <= MAX_RGB_VALUE, "color error")
        }
    }
}
