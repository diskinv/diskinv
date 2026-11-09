//
//  TreeMapView.swift
//  Disk Inventory Xs
//
//  Swift port of TreeMapView.{h,m}. The NSView that owns the renderer tree,
//  draws the cached treemap bitmap, does hit testing, selection, zoom animation,
//  tracking/tooltips, and dispatches to its data source / delegate (informal
//  protocols).
//
//  The data source / delegate outlets stay untyped (Any?) so the nib wiring and
//  the override-based conformance of the (Swift) TreeMapViewController keep
//  binding; dispatch is dynamic (respondsToSelector: + objc_msgSend via an @objc
//  protocol bitcast), and setDelegate auto-registers the delegate as observer of
//  the view's notifications, exactly like the ObjC original.
//
//  GPL v3
//

import Cocoa

// A cell id is literally a renderer object (ObjC typedef TMVItem* TMVCellId).
typealias TMVCellId = TMVItem

// Notification / userInfo-key constants. Values kept byte-for-byte (note the
// typo'd "DidChangeed" value, preserved). The Swift TreeMapViewController
// observes these by the same name; setDelegate registers using them.
let TreeMapViewItemTouchedNotification = "TreeMapViewItemTouched"
let TreeMapViewSelectionDidChangedNotification = "TreeMapViewSelectionDidChangeed"
let TreeMapViewSelectionIsChangingNotification = "TreeMapViewSelectionIsChanging"
let TMVTouchedItem = "TreeMapViewTouchedItem"

// Data Source Note: Specifying nil as the item refers to the "root" item.
// (there must be one (and only one!) root item)
@objc protocol TreeMapViewDataSource {
    // required
    @objc optional func treeMapView(_ view: TreeMapView?, child index: UInt, ofItem item: Any?) -> Any?
    @objc optional func treeMapView(_ view: TreeMapView?, isNode item: Any?) -> Bool
    @objc optional func treeMapView(_ view: TreeMapView?, numberOfChildrenOfItem item: Any?) -> UInt32
    @objc optional func treeMapView(_ view: TreeMapView?, weightByItem item: Any?) -> UInt64
}

// optional delegate methods
@objc protocol TreeMapViewDelegate {
    @objc(treeMapView:getToolTipByItem:)
    optional func treeMapView(_ view: TreeMapView?, getToolTipByItem item: Any?) -> String?
    @objc(treeMapView:willDisplayItem:withRenderer:)
    optional func treeMapView(_ view: TreeMapView?, willDisplayItem item: Any?, withRenderer renderer: TMVItem?)
    @objc(treeMapView:shouldSelectItem:)
    optional func treeMapView(_ view: TreeMapView?, shouldSelectItem item: Any?) -> Bool
    @objc(treeMapView:willShowMenuForEvent:)
    optional func treeMapView(_ view: TreeMapView?, willShowMenuForEvent event: NSEvent?)
}

// Notifications (informal protocol the delegate auto-registers for)
@objc protocol TreeMapViewNotifications {
    @objc optional func treeMapViewSelectionDidChange(_ notification: Notification)
    @objc optional func treeMapViewSelectionIsChanging(_ notification: Notification) // not yet implemented
    @objc optional func treeMapViewItemTouched(_ notification: Notification)
}

@objc(TreeMapView)
final class TreeMapView: NSView, NSViewToolTipOwner {

    private var _rootItemRenderer: TMVItem?
    private var _delegate: Any?
    private var _dataSource: Any?
    private var _selectedRenderer: TMVItem?
    private var _touchedRenderer: TMVItem?
    private var _cachedContent: NSBitmapImageRep?
    private var _zoomer: ZoomInfo?        // non-nil while zooming; doubles as the "are we zooming" flag

    // The IBOutlet delegate/dataSource stay untyped (id/Any?) with the bare names
    // so nib/KVC wires them; setters do the custom validation/auto-registration.
    @objc var delegate: Any? {
        get { _delegate }
        set { setDelegate(newValue) }
    }

    @objc var dataSource: Any? {
        get { _dataSource }
        set { setDataSource(newValue) }
    }

    // dynamic-dispatch bitcast helpers (see TMVItem for the rationale)
    private var delegateProto: TreeMapViewDelegate? {
        guard let d = _delegate else { return nil }
        return unsafeBitCast(d as AnyObject, to: TreeMapViewDelegate.self)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // we have no overlapping views
        postsFrameChangedNotifications = true

        let nc = NotificationCenter.default
        // we want to know if we were resized
        nc.addObserver(self, selector: #selector(viewFrameDidChangeNotification(_:)),
                       name: NSView.frameDidChangeNotification, object: self)

        // these 2 notifications are sent by our window when it gains or looses focus
        nc.addObserver(self, selector: #selector(windowDidResignKey(_:)),
                       name: NSWindow.didResignKeyNotification, object: window)
        nc.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                       name: NSWindow.didBecomeKeyNotification, object: window)
    }

    override func awakeFromNib() {
        let trackingArea = NSTrackingArea(rect: bounds,
                                          options: [.mouseMoved, .inVisibleRect, .activeInActiveApp],
                                          owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        // we defer the creation of the renderers till "reloadData" is called explicitly
    }

    deinit {
        let nc = NotificationCenter.default
        nc.removeObserver(self)
        // remove our delegate for all our notifications
        if let delegate = _delegate {
            nc.removeObserver(delegate, name: nil, object: self)
        }
        deallocContentCache()
    }

    private func setDelegate(_ newDelegate: Any?) {
        assert(newDelegate != nil)

        let nc = NotificationCenter.default

        if let delegate = _delegate {
            nc.removeObserver(delegate, name: nil, object: self)
        }

        _delegate = newDelegate

        // register our delegate as observer for all our notifications
        func registerDelegate(_ selector: Selector, _ notification: String) {
            if let delegate = _delegate as? NSObject, delegate.responds(to: selector) {
                nc.addObserver(delegate, selector: selector,
                               name: NSNotification.Name(notification), object: self)
            }
        }

        registerDelegate(#selector(TreeMapViewNotifications.treeMapViewSelectionDidChange(_:)),
                         TreeMapViewSelectionDidChangedNotification)
        registerDelegate(#selector(TreeMapViewNotifications.treeMapViewSelectionIsChanging(_:)),
                         TreeMapViewSelectionIsChangingNotification)
        registerDelegate(#selector(TreeMapViewNotifications.treeMapViewItemTouched(_:)),
                         TreeMapViewItemTouchedNotification)
    }

    private func setDataSource(_ newDataSource: Any?) {
        _dataSource = newDataSource

        // check that the data source implements all the required methods
        func raise(_ method: String) -> Never {
            NSException(name: .internalInconsistencyException,
                        reason: "data source doesn't respond to '\(method)'",
                        userInfo: nil).raise()
            fatalError()
        }

        let ds = newDataSource as? NSObject
        if ds?.responds(to: #selector(TreeMapViewDataSource.treeMapView(_:child:ofItem:))) != true {
            raise("(id) treeMapView: (TreeMapView*) view child: (unsigned) index ofItem: (id) item")
        }
        if ds?.responds(to: #selector(TreeMapViewDataSource.treeMapView(_:isNode:))) != true {
            raise("(BOOL) treeMapView: (TreeMapView*) view isNode: (id) item")
        }
        if ds?.responds(to: #selector(TreeMapViewDataSource.treeMapView(_:numberOfChildrenOfItem:))) != true {
            raise("(unsigned) treeMapView: (TreeMapView*) view numberOfChildrenOfItem: (id) item")
        }
        if ds?.responds(to: #selector(TreeMapViewDataSource.treeMapView(_:weightByItem:))) != true {
            raise("(unsigned long long) treeMapView: (TreeMapView*) view weightByItem: (id) item")
        }
    }

    override func draw(_ rect: NSRect) {
        // anything to draw?
        guard let root = _rootItemRenderer, root.childCount() != 0 else {
            return
        }

        // If the window is being resized, we just scale the image we have and do
        // not rebuild the tree map according to the new dimensions (would be too slow).
        if inLiveResize {
            if let cachedContent = _cachedContent {
                // temporary NSImage wrapping the BitmapRep, so we can use NSImage's drawing
                let image = cachedContent.suitableImage(for: self)
                let imageSize = image.size
                // draw image slightly dimmed
                image.draw(in: bounds,
                           from: NSRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height),
                           operation: .copy, fraction: 0.6, respectFlipped: true, hints: nil)
            } else {
                NSDrawWindowBackground(rect)
            }
        } else if let zoomer = _zoomer {
            // are we currently zooming in or out?
            zoomer.drawImage()
        } else {
            // "regular" drawing — if our size has changed, re-layout items
            var viewBounds = bounds
            // the tree map item renderers work in the coordinate system of the window's backing store
            viewBounds = convertRectToBackingRespectingFlipped(viewBounds)

            let updateLayout = !NSEqualRects(viewBounds, root.rect())
            if updateLayout {
                root.calcLayout(viewBounds)
                deallocContentCache()
            }

            // this does nothing if the cached image already exists
            drawInCache()

            // temporary NSImage wrapping the BitmapRep
            if let image = _cachedContent?.suitableImage(for: self) {
                image.draw(in: rect, from: rect, operation: .copy, fraction: 1,
                           respectFlipped: true, hints: nil)
            }

            if let selectedRenderer = _selectedRenderer {
                selectedRenderer.drawHighlightFrame()
            }
        }
    }

    // To opt-in for the focus ring drawing model, override drawFocusRingMask ...
    override func drawFocusRingMask() {
        bounds.fill()
    }

    // ... and focusRingMaskBounds to return the element's bounding box.
    override var focusRingMaskBounds: NSRect {
        bounds
    }

    override func mouseDown(with theEvent: NSEvent) {
        var point = theEvent.locationInWindow
        point = convert(point, from: nil)
        point.y -= 1

        // the renderers work in backing-store coordinates, so convert the point
        point = convertPointToBackingRespectingFlipped(point)

        // find the hit item
        let renderer = _rootItemRenderer?.hitTest(point)

        if renderer !== _selectedRenderer {
            _selectedRenderer = renderer

            // post notification
            NotificationCenter.default.post(name: NSNotification.Name(TreeMapViewSelectionDidChangedNotification),
                                            object: self, userInfo: nil)
            needsDisplay = true
        }
    }

    override func rightMouseDown(with theEvent: NSEvent) {
        if acceptsFirstResponder && window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        super.rightMouseDown(with: theEvent)
    }

    override func mouseMoved(with theEvent: NSEvent) {
        // if we are not first responder, super will forward to the window
        if window?.firstResponder === self {
            super.mouseMoved(with: theEvent)
        }

        var point = theEvent.locationInWindow
        point = convert(point, from: nil)
        point.y -= 1

        // the renderers work in backing-store coordinates, so convert
        let pointPixel = convertPointToBackingRespectingFlipped(point)

        // first test if the mouse is still in the same item
        if let touched = _touchedRenderer, touched.hitTest(pointPixel) != nil {
            return
        }

        // the mouse moved to a new item, so look for the new one
        let renderer = _rootItemRenderer?.hitTest(pointPixel)

        if renderer === _touchedRenderer {
            assert(renderer == nil, "why this?")
            return
        }

        _touchedRenderer = renderer

        let touchedItem: Any? = _touchedRenderer?.item()

        // set tooltip
        var newToolTip: String?
        if let touchedItem = touchedItem,
           (delegate as? NSObject)?.responds(to: #selector(TreeMapViewDelegate.treeMapView(_:getToolTipByItem:))) == true {
            newToolTip = delegateProto?.treeMapView?(self, getToolTipByItem: touchedItem) ?? nil
        }
        toolTip = newToolTip

        // post notification about the touched item
        let userInfo: [AnyHashable: Any] = (touchedItem == nil) ? [:] : [TMVTouchedItem: touchedItem!]
        NotificationCenter.default.post(name: NSNotification.Name(TreeMapViewItemTouchedNotification),
                                        object: self, userInfo: userInfo)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if (delegate as? NSObject)?.responds(to: #selector(TreeMapViewDelegate.treeMapView(_:willShowMenuForEvent:))) == true {
            delegateProto?.treeMapView?(self, willShowMenuForEvent: event)
        }
        return super.menu(for: event)
    }

    @objc(cellIdByPoint:inViewCoords:)
    func cellId(by point: NSPoint, inViewCoords viewCoords: Bool) -> TMVCellId? {
        var point = point
        if !viewCoords {
            point = convert(point, from: nil)
        }
        // the renderers work in backing-store coordinates, so convert
        point = convertPointToBackingRespectingFlipped(point)
        return _rootItemRenderer?.hitTest(point)
    }

    @objc
    func selectedItem() -> Any? {
        _selectedRenderer?.item()
    }

    @objc(itemByCellId:)
    func item(byCellId cellId: TMVCellId) -> Any? {
        cellId.item()
    }

    @objc(selectItemByCellId:)
    func selectItem(byCellId cellId: TMVCellId?) {
        if cellId !== _selectedRenderer {
            _selectedRenderer = cellId

            // post notification
            NotificationCenter.default.post(name: NSNotification.Name(TreeMapViewSelectionDidChangedNotification),
                                            object: self, userInfo: nil)
            needsDisplay = true
        }
    }

    @objc(selectItemByPathToItem:)
    func selectItemByPath(toItem path: [Any]) {
        // path must at least contain one item (the root item)
        assert(path.count > 0, "path must contain at least 1 component")

        if let rendererToSelect = findTMVItem(byPathToDataItem: path) {
            selectItem(byCellId: rendererToSelect)
        }
    }

    @objc(itemRectByCellId:)
    func itemRect(byCellId cellId: TMVCellId) -> NSRect {
        // the renderers work in backing-store coordinates, so convert
        convertRectFromBackingRespectingFlipped(cellId.rect())
    }

    // rect in view coords; item is identified by path from root to item
    @objc(itemRectByPathToItem:)
    func itemRectByPath(toItem path: [Any]) -> NSRect {
        // path must at least contain one item (the root item)
        assert(path.count > 0, "path must contain at least 1 component")

        if let renderer = findTMVItem(byPathToDataItem: path) {
            // the renderers work in backing-store coordinates, so convert
            return convertRectFromBackingRespectingFlipped(renderer.rect())
        }
        return .zero
    }

    @objc
    func invalidateCanvasCache() {
        // just delete the cached view content
        deallocContentCache()
    }

    @objc
    func reloadData() {
        assert(!zoomingInProgress(), "cannot reload tree map while zooming is in progress")

        deallocContentCache()

        _selectedRenderer = nil
        _touchedRenderer = nil

        if _rootItemRenderer == nil {
            _rootItemRenderer = TMVItem(dataSource: dataSource, delegate: delegate,
                                        renderedItem: nil, treeMapView: self)
        } else {
            _rootItemRenderer?.refresh(withItem: nil)
        }

        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)

        needsDisplay = true
    }

    @objc(reloadAndPerformZoomIntoItem:)
    func reloadAndPerformZoom(intoItem path: [Any]) {
        assert(!zoomingInProgress(), "cannot reload tree map while zooming is in progress")
        // path must at least contain one item (the root item)
        assert(path.count > 0, "path must contain at least 1 component")

        var viewBounds = bounds
        // the renderers work in backing-store coordinates, so convert
        viewBounds = convertRectToBackingRespectingFlipped(viewBounds)

        // just reload if item to zoom in is too small
        let renderer = findTMVItem(byPathToDataItem: path)
        if renderer == nil
            || NSEqualRects(viewBounds, renderer!.rect())
            || renderer!.rect().width <= 4 || renderer!.rect().height <= 4 {
            if renderer == nil {
                NSLog("item to zoom in wasn't found")
            }
            reloadData()
            return
        }

        var oldImageRep: NSBitmapImageRep?
        if _cachedContent == nil {
            oldImageRep = NSBitmapImageRep.imageRepCompatible(with: self)
            _rootItemRenderer?.calcLayout(viewBounds)
            if let oldImageRep = oldImageRep {
                _rootItemRenderer?.drawCushion(inBitmap: oldImageRep)
            }
        } else {
            oldImageRep = _cachedContent
        }

        let zoomStartRect = renderer!.rect()

        // before we animate, make sure the new content is loaded and rendered so it
        // can be drawn immediately after the zooming has finished
        reloadData()
        _rootItemRenderer?.calcLayout(viewBounds)
        deallocContentCache()
        drawInCache()

        // was set to YES in reloadData
        needsDisplay = false

        if let oldImageRep = oldImageRep {
            let zoomer = ZoomInfo(image: oldImageRep.suitableImage(for: self),
                                  delegate: self, selector: #selector(performZoom(_:)))
            _zoomer = zoomer
            zoomer.calculateZoom(fromRect: zoomStartRect, toRect: viewBounds)
        }
    }

    @objc(reloadAndPerformZoomOutofItem:)
    func reloadAndPerformZoomOutofItem(_ path: [Any]) {
        assert(!zoomingInProgress(), "cannot reload tree map while zooming is in progress")
        // path must at least contain one item (the root item)
        assert(path.count > 0, "path must contain at least 1 component")

        let viewBounds = bounds

        // reload and render content
        reloadData()
        _rootItemRenderer?.calcLayout(viewBounds)
        deallocContentCache()
        drawInCache()

        // do nothing if item to zoom in is too small
        let renderer = findTMVItem(byPathToDataItem: path)
        if renderer == nil
            || NSEqualRects(viewBounds, renderer!.rect())
            || renderer!.rect().width <= 4 || renderer!.rect().height <= 4 {
            if renderer == nil {
                NSLog("item to zoom out wasn't found")
            }
            return
        }

        // was set to YES in reloadData
        needsDisplay = false

        if let cachedContent = _cachedContent {
            let zoomer = ZoomInfo(image: cachedContent.suitableImage(for: self),
                                  delegate: self, selector: #selector(performZoom(_:)))
            _zoomer = zoomer
            zoomer.calculateZoom(fromRect: viewBounds, toRect: renderer!.rect())
        }
    }

    @objc
    func zoomingInProgress() -> Bool {
        _zoomer != nil
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        // tooltips don't work satisfyingly, so disable them
        ""
    }

    override func viewDidEndLiveResize() {
        addToolTip(bounds, owner: self, userData: nil)
        needsDisplay = true
    }

    override func viewWillStartLiveResize() {
        removeAllToolTips()
    }

    @objc private func viewFrameDidChangeNotification(_ notification: Notification) {
        if !inLiveResize {
            removeAllToolTips()
            addToolTip(bounds, owner: self, userData: nil)
        }
    }

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    // we're about to get the input focus, so invalidate the area of the focus rect
    override func becomeFirstResponder() -> Bool {
        if !super.resignFirstResponder() {
            return false
        }
        setKeyboardFocusRingNeedsDisplay(visibleRect)
        return true
    }

    // we're about to lose the input focus, so invalidate the area of the focus rect
    override func resignFirstResponder() -> Bool {
        if !super.resignFirstResponder() {
            return false
        }
        setKeyboardFocusRingNeedsDisplay(visibleRect)
        return true
    }

    // our window is no longer key, so invalidate the area of our focus rect
    @objc private func windowDidResignKey(_ aNotification: Notification) {
        if window?.firstResponder === self {
            setKeyboardFocusRingNeedsDisplay(visibleRect)
        }
    }

    // our window has become key, so invalidate the area of our focus rect
    @objc private func windowDidBecomeKey(_ aNotification: Notification) {
        if window?.firstResponder === self {
            setKeyboardFocusRingNeedsDisplay(visibleRect)
        }
    }

    override var canBecomeKeyView: Bool {
        true
    }

    override var isOpaque: Bool {
        true
    }

    // Invoked when the view's backing properties change.
    override func viewDidChangeBackingProperties() {
        // just invalidate; our drawing function will detect the change and reallocate the cache bitmap
        needsDisplay = true
    }

    @objc(benchmarkLayoutCalculationWithImageSize:count:)
    func benchmarkLayoutCalculation(withImageSize size: NSSize, count: UInt32) {
        let tmvItem = TMVItem(dataSource: dataSource, delegate: delegate,
                              renderedItem: nil, treeMapView: self)

        var count = count / 2
        let size2 = NSSize(width: size.width * 2, height: size.height * 2)

        while count > 0 {
            tmvItem.calcLayout(NSRect(x: 0, y: 0, width: size.width, height: size.height))
            tmvItem.calcLayout(NSRect(x: 0, y: 0, width: size2.width, height: size2.height))
            count -= 1
        }
    }

    @objc(benchmarkRenderingWithImageSize:count:)
    func benchmarkRendering(withImageSize size: NSSize, count: UInt32) {
        // 24-bit RGB bitmap, no alpha
        guard let bitmap = NSBitmapImageRep(rgbBitmapWithWidth: Int(size.width), height: Int(size.height)) else { return }

        let tmvItem = TMVItem(dataSource: dataSource, delegate: delegate,
                              renderedItem: nil, treeMapView: self)
        tmvItem.calcLayout(NSRect(x: 0, y: 0, width: size.width, height: size.height))

        var count = count
        while count > 0 {
            tmvItem.drawCushion(inBitmap: bitmap)
            count -= 1
        }
    }

    // MARK: - Private

    private func drawInCache() {
        if _cachedContent != nil {
            return
        }
        allocContentCache()
        if let root = _rootItemRenderer, let cache = _cachedContent {
            root.drawCushion(inBitmap: cache)
        }
    }

    private func allocContentCache() {
        _cachedContent = NSBitmapImageRep.imageRepCompatible(with: self)
    }

    private func deallocContentCache() {
        _cachedContent = nil
    }

    private func findTMVItem(byPathToDataItem path: [Any]) -> TMVItem? {
        guard let root = _rootItemRenderer else { return nil }
        assert(path.count > 0, "path must contain at least 1 component")

        var parent = root
        var child: TMVItem? = root

        // we start with the second item, as the first corresponds to our root
        for dataItem in path.dropFirst() {
            let dataObj = dataItem as AnyObject
            child = nil

            // find renderer displaying "dataItem"
            let childEnum = parent.childEnumerator()
            while let candidate = childEnum.nextObject() as? TMVItem {
                if (candidate.item() as AnyObject?) === dataObj {
                    child = candidate
                    break
                }
            }

            guard let foundChild = child else {
                return nil // not found
            }
            parent = foundChild
        }

        return child
    }

    @objc private func performZoom(_ zoomInfo: ZoomInfo) {
        assert(_zoomer === zoomInfo)

        display()

        if zoomInfo.hasFinished() {
            _zoomer = nil
            needsDisplay = true
        }
    }
}
