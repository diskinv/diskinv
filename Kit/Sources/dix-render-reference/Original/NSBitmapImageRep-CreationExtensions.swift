//
//  NSBitmapImageRep-CreationExtensions.swift
//  Disk Inventory Xs
//
//  Swift port of NSBitmapImageRep-CreationExtensions.{h,m}. Convenience
//  constructors for the 24-bit RGB no-alpha bitmaps the treemap renderer needs,
//  plus a view-aware factory and an NSImage wrapper. The selectors are pinned
//  with @objc so the existing Swift call sites
//  (NSBitmapImageRep(rgbBitmapWithWidth:height:), suitableImage(for:),
//  imageRepCompatible(with:)) keep their names.
//
//  GPL v3
//

import Cocoa

extension NSBitmapImageRep {

    // creates a bitmap image rep with size (respecting scaling factor) and color space of the view
    @objc(imageRepCompatibleWithView:)
    static func imageRepCompatible(with view: NSView) -> NSBitmapImageRep? {
        let viewBounds = view.bounds
        let sizePoints = viewBounds.size
        let sizePixel = view.convertToBacking(sizePoints)

        guard var imgRep = NSBitmapImageRep(rgbBitmapWithWidth: Int(sizePixel.width),
                                            height: Int(sizePixel.height))
        else { return nil }

        // Setting the user size communicates the dpi
        imgRep.size = sizePoints

        // set color space
        if let window = view.window {
            // retag image rep with window's color space
            // (we have to do that after the creation as there is no color space constant for the sRGB space)
            let colorSpace = window.colorSpace
            if let colorSpace = colorSpace,
               let imgRepWithCorrectCS = imgRep.retagging(with: colorSpace) {
                imgRep = imgRepWithCorrectCS
            }
        }

        return imgRep
    }

    // creates a Bitmap with 24 bit color depth and no alpha component
    @objc(initRGBBitmapWithWidth:height:)
    convenience init?(rgbBitmapWithWidth width: Int, height: Int) {
        self.init(bitmapDataPlanes: nil,            // Let the class allocate it
                  pixelsWide: width,
                  pixelsHigh: height,
                  bitsPerSample: 8,                 // Each component is 8 bits (one byte)
                  samplesPerPixel: 3,               // Number of components (R, G, B, no alpha)
                  hasAlpha: false,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,                   // 0 means: Let the class figure it out
                  bitsPerPixel: 0)                  // 0 means: Let the class figure it out
    }

    // creates an NSImage with the same dimensions as the NSBitmapImageRep and adds
    // the NSBitmapImageRep as the only image representation
    @objc(suitableImageForView:)
    func suitableImage(for view: NSView) -> NSImage {
        let image = NSImage(size: size)
        image.addRepresentation(self)
        return image
    }
}
