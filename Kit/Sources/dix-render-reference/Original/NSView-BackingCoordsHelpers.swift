//
//  NSView-BackingCoordsHelpers.swift
//  Disk Inventory Xs
//
//  Swift port of NSView-BackingCoordsHelpers.{h,m}. Backing-store coordinate
//  conversions that handle flipped views: the stock convert…ToBacking /
//  …FromBacking methods mishandle flipped views, so these negate point.y when
//  the view is flipped. Internal to the TreeMap framework (not bridged). The
//  methods are pinned with @objc so the still-Objective-C TreeMapView/TMVItem
//  callers reach them via the generated header; once those are ported the @objc
//  could be dropped, but keeping it is harmless.
//
//  GPL v3
//

import Cocoa

extension NSView {

    /* the NSView methods convertXXXToBacking and convertXXXFromBacking have problems with flipped views */

    @objc(convertPointToBackingRespectingFlipped:)
    func convertPointToBackingRespectingFlipped(_ point: NSPoint) -> NSPoint {
        var point = convertToBacking(point)
        if isFlipped {
            point.y *= -1
        }
        return point
    }

    @objc(convertPointFromBackingRespectingFlipped:)
    func convertPointFromBackingRespectingFlipped(_ point: NSPoint) -> NSPoint {
        var point = convertFromBacking(point)
        if isFlipped {
            point.y *= -1
        }
        return point
    }

    @objc(convertSizeToBackingRespectingFlipped:)
    func convertSizeToBackingRespectingFlipped(_ size: NSSize) -> NSSize {
        // no need for special handling flipped views here
        convertToBacking(size)
    }

    @objc(convertSizeFromBackingRespectingFlipped:)
    func convertSizeFromBackingRespectingFlipped(_ size: NSSize) -> NSSize {
        // no need for special handling flipped views here
        convertFromBacking(size)
    }

    @objc(convertRectToBackingRespectingFlipped:)
    func convertRectToBackingRespectingFlipped(_ rect: NSRect) -> NSRect {
        var rect = rect
        rect.origin = convertPointToBackingRespectingFlipped(rect.origin)
        rect.size = convertSizeToBackingRespectingFlipped(rect.size)
        return rect
    }

    @objc(convertRectFromBackingRespectingFlipped:)
    func convertRectFromBackingRespectingFlipped(_ rect: NSRect) -> NSRect {
        var rect = rect
        rect.origin = convertPointFromBackingRespectingFlipped(rect.origin)
        rect.size = convertSizeFromBackingRespectingFlipped(rect.size)
        return rect
    }
}
