//
//  ZoomInfo.swift
//  Disk Inventory Xs
//
//  Swift port of ZoomInfo.{h,m}. Drives the zoom-in/out animation: holds the
//  pre-zoom snapshot image, the current animated rect, per-step deltas, and an
//  NSTimer that calls back the delegate each frame. Internal to the TreeMap
//  framework (not bridged), but pinned @objc(ZoomInfo) so the still-ObjC
//  TreeMapView reaches it via the generated header.
//
//  GPL v3
//

import Cocoa

@objc(ZoomInfo)
final class ZoomInfo: NSObject {

    private let _image: NSImage
    private var _rect: NSRect = .zero
    private var _zoomStepsLeft: UInt = 0
    private var _leftStep: Float = 0
    private var _topStep: Float = 0
    private var _rightStep: Float = 0
    private var _bottomStep: Float = 0
    private weak var _delegate: AnyObject?
    private let _delegateSelector: Selector
    private var _timer: Timer?

    @objc(initWithImage:delegate:selector:)
    init(image: NSImage, delegate: Any, selector: Selector) {
        _image = image
        _delegate = delegate as AnyObject
        _delegateSelector = selector
        assert((delegate as AnyObject).responds(to: selector),
               "delegate doesn't respond to given selector")
        _rect = .zero
        super.init()
    }

    @objc(calculateZoomFromRect:toRect:)
    func calculateZoom(fromRect startRect: NSRect, toRect endRect: NSRect) {
        // if the shift key is down, we slow the zoom effect down (like e.g. the dock)
        // (To determine this ([[NSApp currentEvent] modifierFlags] & NSShiftKeyMask)
        // should do it, but it don't. So ask OAApplication, if present)
        var shiftKeyPressed = false
        let checkSel = NSSelectorFromString("checkForModifierFlags:")
        if NSApp.responds(to: checkSel) {
            // optional NSApplication(Omni) -checkForModifierFlags:
            let result = NSApp.perform(checkSel, with: Int(NSEvent.ModifierFlags.shift.rawValue) as NSNumber)
            shiftKeyPressed = (result != nil)
        }

        let zoomIn = endRect.contains(startRect)

        _rect = zoomIn ? endRect : startRect

        let maxPixelToZoom = max(abs(Float(endRect.width) - Float(startRect.width)),
                                 abs(Float(endRect.height) - Float(startRect.height)))

        let zoomStepCount = maxPixelToZoom / (shiftKeyPressed ? 10.0 : 40.0)

        let zoomFactorX = zoomIn
            ? Float(endRect.width) / Float(startRect.width)
            : Float(startRect.width) / Float(endRect.width)
        let zoomFactorY = zoomIn
            ? Float(endRect.height) / Float(startRect.height)
            : Float(startRect.height) / Float(endRect.height)

        _leftStep = (Float(startRect.minX) - Float(endRect.minX)) / zoomStepCount * zoomFactorX
        _topStep = (Float(startRect.minY) - Float(endRect.minY)) / zoomStepCount * zoomFactorY
        _rightStep = (Float(endRect.maxX) - Float(startRect.maxX)) / zoomStepCount * zoomFactorX
        _bottomStep = (Float(endRect.maxY) - Float(startRect.maxY)) / zoomStepCount * zoomFactorY

        if !zoomIn {
            _rect.origin.x += CGFloat(_leftStep * zoomStepCount)
            _rect.origin.y += CGFloat(_topStep * zoomStepCount)
            _rect.size.width -= CGFloat((_rightStep + _leftStep) * zoomStepCount)
            _rect.size.height -= CGFloat((_bottomStep + _topStep) * zoomStepCount)
        }

        _zoomStepsLeft = UInt(zoomStepCount.rounded())

        let timer = Timer(timeInterval: 0.03,
                          target: self,
                          selector: #selector(onTimer(_:)),
                          userInfo: nil,
                          repeats: true)

        // run loop will retain the timer object
        RunLoop.current.add(timer, forMode: .default)
        _timer = timer
    }

    deinit {
        if let timer = _timer, timer.isValid {
            timer.invalidate() // timer will be released by run loop
        }
        _timer = nil
    }

    private func calculateNewRect() {
        _rect.origin.x -= CGFloat(_leftStep)
        _rect.origin.y -= CGFloat(_topStep)
        _rect.size.width += CGFloat(_rightStep + _leftStep)
        _rect.size.height += CGFloat(_bottomStep + _topStep)
    }

    @objc private func onTimer(_ timer: Timer) {
        assert(timer == _timer, "unknown timer")
        assert(timer.isValid, "invalid timer")

        calculateNewRect()

        if _zoomStepsLeft > 0 {
            _zoomStepsLeft -= 1
        }

        if _zoomStepsLeft <= 0 {
            _timer?.invalidate()
            _timer = nil // timer will be released by run loop
        }

        _delegate?.perform(_delegateSelector, with: self)
    }

    @objc
    func hasFinished() -> Bool {
        _zoomStepsLeft <= 0
    }

    @objc
    func image() -> NSImage {
        _image
    }

    @objc
    func imageRect() -> NSRect {
        _rect
    }

    @objc
    func drawImage() {
        let currentInterpolation = NSGraphicsContext.current?.imageInterpolation ?? .default
        NSGraphicsContext.current?.imageInterpolation = .low

        let imageSize = _image.size

        _image.draw(in: _rect,
                    from: NSRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height),
                    operation: .copy,
                    fraction: 1 /*requestedAlpha*/,
                    respectFlipped: true,
                    hints: nil)

        NSGraphicsContext.current?.imageInterpolation = currentInterpolation
    }
}
