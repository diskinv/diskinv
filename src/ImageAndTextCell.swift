//
//  ImageAndTextCell.swift
//  Disk Inventory Xs
//
//  Swift port of ImageAndTextCell.{h,m} (originally Apple's
//  DragNDropOutlineView sample). An NSTextFieldCell subclass that draws an
//  image to the left of the text. Used as the data cell for the file-browser
//  outline column and the selection-list "displayName" column (set in code,
//  copied by the table machinery), so the class name and image accessors are
//  pinned with @objc.
//
//  GPL v3
//

import Cocoa

@objc(ImageAndTextCell)
class ImageAndTextCell: NSTextFieldCell {

    private static let textOffset: CGFloat = 10  // space between image and text
    private static let imageOffset: CGFloat = 5  // space between cell's left edge and image

    private var _image: NSImage?

    // overrides NSCell.image so the per-row icon set by the table delegate is
    // the one drawWithFrame renders
    override var image: NSImage? {
        get { _image }
        set { _image = newValue }
    }

    @objc(cell)
    class func cell() -> ImageAndTextCell {
        ImageAndTextCell(textCell: "")
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        // NSCell copies raw instance storage without retaining Swift properties.
        // Keep the image out of that shallow copy, then assign it through ARC.
        let image = _image
        _image = nil
        defer { _image = image }

        let cell = super.copy(with: zone) as! ImageAndTextCell
        cell._image = image
        return cell
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        let (_, textFrame) = rect.divided(atDistance: Self.textOffset + (_image?.size.width ?? 0),
                                          from: .minXEdge)
        super.edit(withFrame: textFrame, in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        let (_, textFrame) = rect.divided(atDistance: Self.textOffset + (_image?.size.width ?? 0),
                                          from: .minXEdge)
        super.select(withFrame: textFrame, in: controlView, editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        var cellFrame = cellFrame
        // the default-font row height is 17px, so draw the icon at 16x16
        let imageSize: NSSize = (_image == nil) ? .zero : NSSize(width: 16, height: 16)

        let (slice, remainder) = cellFrame.divided(atDistance: Self.textOffset + imageSize.width,
                                                   from: .minXEdge)
        var imageFrame = slice
        cellFrame = remainder

        if drawsBackground {
            backgroundColor?.set()
            imageFrame.fill()
        }

        if let image = _image {
            imageFrame.origin.x += Self.imageOffset
            imageFrame.size = imageSize

            if controlView.isFlipped {
                imageFrame.origin.y += ceil((cellFrame.size.height + imageFrame.size.height) / 2)
            } else {
                imageFrame.origin.y += ceil((cellFrame.size.height - imageFrame.size.height) / 2)
            }

            image.draw(at: imageFrame.origin, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        if let font = self.font {
            stringValue = Self.stringByTruncating(toWidth: cellFrame.width, font: font, string: stringValue)
        }

        super.draw(withFrame: cellFrame, in: controlView)
    }

    override var cellSize: NSSize {
        var size = super.cellSize
        size.width += (_image?.size.width ?? 0) + Self.textOffset
        return size
    }

    private static func stringByTruncating(toWidth width: CGFloat, font: NSFont, string: String) -> String {
        let attribs: [NSAttributedString.Key: Any] = [.font: font]

        // only truncate if the string is wider than the available width
        guard (string as NSString).size(withAttributes: attribs).width > width else {
            return string
        }

        let ellipsis = "\u{2026}"
        let available = width - (ellipsis as NSString).size(withAttributes: attribs).width
        if available < 0 {
            // not enough room for anything: just the ellipsis
            return ellipsis
        }

        let truncated = NSMutableString(string: string)
        var range = NSRange(location: truncated.length - 1, length: 1)
        while truncated.size(withAttributes: attribs).width > available && range.location > 0 {
            truncated.deleteCharacters(in: range)
            range.location -= 1
        }
        truncated.replaceCharacters(in: range, with: ellipsis)
        return truncated as String
    }
}
