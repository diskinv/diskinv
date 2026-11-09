//
//  PNG.swift
//  DIXTreemap
//
//  PNG in/out for bitmaps (ImageIO), for the CLIs and tests.
//
//  GPL v3
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum TreemapImageError: Error {
    case cannotEncode
    case cannotDecode
}

extension TreemapBitmap {
    public func writePNG(to url: URL) throws {
        guard let image = makeCGImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw TreemapImageError.cannotEncode }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw TreemapImageError.cannotEncode }
    }

    /// Reads a PNG back as raw 8-bit RGBA, without color conversion.
    public init(contentsOfPNG url: URL) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw TreemapImageError.cannotDecode }
        self.init(width: image.width, height: image.height)
        // draw into a context with the image's own color space so no conversion happens
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let w = width, h = height
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw TreemapImageError.cannotDecode }
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
    }
}
