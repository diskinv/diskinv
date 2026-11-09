//
//  TMVItem.swift
//  Disk Inventory Xs
//
//  Swift port of TMVItem.{h,m}. One treemap cell = layout node + cushion owner.
//  Builds child renderers, computes the squarified layout, recursively renders
//  cushions, hit-tests, and draws grid/highlight. The data source/delegate are
//  the TreeMapView's informal protocols, dispatched dynamically.
//
//  setCushionColor(_:) and the type itself stay @objc because the delegate
//  callback (TreeMapViewController.treeMapView(_:willDisplayItem:withRenderer:))
//  is handed a TMVItem and calls setCushionColor(_:).
//
//  GPL v3
//

import Cocoa

private let CUSHION_SCALE_FACTOR: Float = 0.9

// holds display information about one cell in the treemap
@objc(TMVItem)
final class TMVItem: NSObject {

    private weak var _dataSource: AnyObject?  // tree map view's data source (implements TreeMapViewDataSource)
    private weak var _delegate: AnyObject?    // tree map view's delegate (implements TreeMapViewDelegate)
    private var _item: Any?                    // the data item represented by this tree map item
    private weak var _view: TreeMapView?       // the tree map view to which this item belongs

    private var _rect: NSRect = .zero          // cell rect (in backing coordinates of the tree map view)
    private var _childRenderers: [TMVItem]?
    private let _cushionRenderer: TMVCushionRenderer

    // Lazily-initialized shared drawing colors/attributes (was +initialize statics).
    private static let leafGridColor: NSColor = .disabledControlTextColor
    private static let highlightGridColor: NSColor = .yellow

    @objc(initWithDataSource:delegate:renderedItem:treeMapView:)
    init(dataSource: Any?, delegate: Any?, renderedItem item: Any?, treeMapView view: Any?) {
        _item = item
        _dataSource = dataSource as AnyObject?
        _delegate = delegate as AnyObject?
        _view = view as? TreeMapView
        _rect = .zero
        _cushionRenderer = TMVCushionRenderer()
        super.init()

        if !isLeaf() {
            createChildRenderers()
        }
    }

    @objc(refreshWithItem:)
    func refresh(withItem item: Any?) {
        _item = item
        _rect = .zero
        _cushionRenderer.setRect(.zero)

        if !isLeaf() {
            createChildRenderers()
        } else {
            _childRenderers = nil
        }
    }

    @objc(setCushionColor:)
    func setCushionColor(_ color: NSColor?) {
        // The ObjC original accepted nil (nil-messaging into setColor:); guard it
        // here so a never-in-practice nil can't trap the Swift renderer.
        if let color = color {
            _cushionRenderer.setColor(color)
        }
    }

    @objc(calcLayout:)
    func calcLayout(_ rect: NSRect) {
        if NSEqualRects(_rect, rect) {
            return
        }

        assert(rect.origin.x - CGFloat(Int(rect.origin.x)) == 0.0, "rect.origin.x is not an integral value")
        assert(rect.origin.y - CGFloat(Int(rect.origin.y)) == 0.0, "rect.origin.y is not an integral value")
        assert(rect.size.width - CGFloat(Int(rect.size.width)) == 0.0, "rect.size.width is not an integral value")
        assert(rect.size.height - CGFloat(Int(rect.size.height)) == 0.0, "height is not an integral value")

        _rect = rect
        _cushionRenderer.setRect(rect)

        // if the rect is too small, we do nothing
        if let view = _view {
            let rectPoints = view.convertRectFromBackingRespectingFlipped(_rect)
            if rectPoints.height < 1 || rectPoints.width < 1 {
                return
            }
        }

        if !isLeaf() {
            layoutChilds()
        }
    }

    @objc
    func drawGrid() {
        if isLeaf() {
            guard let view = _view else { return }
            let rectPoints = view.convertRectFromBackingRespectingFlipped(_rect)

            TMVItem.leafGridColor.set()
            __NSFrameRectWithWidthUsingOperation(rectPoints, 1, .copy)
        } else {
            for childRenderer in _childRenderers ?? [] {
                childRenderer.drawGrid()
            }
        }
    }

    @objc
    func drawHighlightFrame() {
        guard let view = _view else { return }
        let rectPoints = view.convertRectFromBackingRespectingFlipped(_rect)

        // if the rect is too small, we do nothing
        if rectPoints.height < 1 || rectPoints.width < 1 {
            return
        }

        TMVItem.highlightGridColor.set()

        let oldLineWidth = NSBezierPath.defaultLineWidth
        NSBezierPath.defaultLineWidth = 2

        NSBezierPath.stroke(rectPoints)

        NSBezierPath.defaultLineWidth = oldLineWidth
    }

    @objc(drawCushionInBitmap:)
    func drawCushion(inBitmap bitmap: NSBitmapImageRep) {
        drawCushion(inBitmap: bitmap, parentCushion: nil, cushionHeightFactor: 0.5)
    }

    // The data source / delegate are informal protocols implemented (via
    // `override`) by an object that does NOT register Swift protocol conformance,
    // so `as? TreeMapViewDataSource` would fail. Bitcast to the @objc protocol
    // type to get type-checked optional-method dispatch (which internally does
    // respondsToSelector: + objc_msgSend), exactly like the ObjC original.
    private var dataSource: TreeMapViewDataSource? {
        guard let ds = _dataSource else { return nil }
        return unsafeBitCast(ds, to: TreeMapViewDataSource.self)
    }

    private var delegate: TreeMapViewDelegate? {
        guard let d = _delegate else { return nil }
        return unsafeBitCast(d, to: TreeMapViewDelegate.self)
    }

    @objc
    func isLeaf() -> Bool {
        guard let ds = dataSource else { return true }
        return !(ds.treeMapView!(_view, isNode: _item))
    }

    @objc
    func item() -> Any? {
        _item
    }

    @objc
    func weight() -> UInt64 {
        guard let ds = dataSource else { return 0 }
        return ds.treeMapView!(_view, weightByItem: _item)
    }

    @objc
    func rect() -> NSRect {
        _rect
    }

    @objc
    func childEnumerator() -> NSEnumerator {
        assert(_childRenderers != nil,
               "method 'childEnumerator' can only be invoked for nodes, not for leafs")
        return (_childRenderers as NSArray? ?? []).objectEnumerator()
    }

    @objc(childAtIndex:)
    func child(at childIndex: UInt) -> TMVItem? {
        _childRenderers?[Int(childIndex)]
    }

    @objc
    func childCount() -> Int {
        _childRenderers?.count ?? 0
    }

    @objc(hitTest:)
    func hitTest(_ aPoint: NSPoint) -> TMVItem? {
        if !NSPointInRect(aPoint, _rect) {
            return nil
        }

        if isLeaf() {
            return self
        } else {
            for childRenderer in _childRenderers ?? [] {
                if let hit = childRenderer.hitTest(aPoint) {
                    return hit
                }
            }
            return nil
        }
    }

    // MARK: - Private

    private func drawCushion(inBitmap bitmap: NSBitmapImageRep,
                             parentCushion: TMVCushionRenderer?,
                             cushionHeightFactor heightFactor: Float) {
        // if the rect is too small, we do nothing
        if let view = _view {
            let rectPoints = view.convertRectFromBackingRespectingFlipped(_rect)
            if rectPoints.height < 1 || rectPoints.width < 1 {
                return
            }
        }

        if let parentCushion = parentCushion {
            _cushionRenderer.setSurface(parentCushion.surface())
            _cushionRenderer.addRidge(byHeightFactor: heightFactor)
        }

        if isLeaf() {
            if let delegate = delegate,
               (_delegate?.responds(to: #selector(TreeMapViewDelegate.treeMapView(_:willDisplayItem:withRenderer:))) ?? false) {
                delegate.treeMapView!(_view, willDisplayItem: _item, withRenderer: self)
            }

            _cushionRenderer.renderCushion(inBitmap: bitmap)
        } else {
            for child in _childRenderers ?? [] {
                child.drawCushion(inBitmap: bitmap,
                                  parentCushion: _cushionRenderer,
                                  cushionHeightFactor: heightFactor * CUSHION_SCALE_FACTOR)
            }
        }
    }

    private func layoutChilds() {
        guard let childRenderers = _childRenderers else { return }

        var rows: [Double] = []              // fraction of total height for each row
        var childsPerRow: [Int] = []         // number of childs per row
        var childWidths: [Double] = []       // fraction of total width for each child

        var horizontalRows = false
        arrangeChildsOnRows(rows: &rows, childsPerRow: &childsPerRow,
                            childWidths: &childWidths, rowsAreHoriz: &horizontalRows)

        let parentWidth = Int(horizontalRows ? _rect.width : _rect.height)
        let parentHeight = Int(horizontalRows ? _rect.height : _rect.width)

        let parentBottom = Int(horizontalRows ? _rect.maxY : _rect.maxX)
        let parentRight = Int(horizontalRows ? _rect.maxX : _rect.maxY)
        let parentLeft = Int(horizontalRows ? _rect.minX : _rect.minY)

        var childIndex = 0

        var top = Int(horizontalRows ? _rect.minY : _rect.minX)

        for row in 0..<rows.count {
            var bottom = top + Int((rows[row] * Double(parentHeight)).rounded())
            // if this is the last row, make sure its bottom is the same as ours (kill rounding errors)
            if bottom > parentBottom || row == rows.count - 1 {
                bottom = parentBottom
            }

            var left = parentLeft

            let columns = childsPerRow[row]
            for column in 0..<columns {
                var right = left + Int((childWidths[childIndex] * Double(parentWidth)).rounded())
                // if this is the last child in the current row, make sure its rect ends with ours
                if right > parentRight || column == columns - 1 {
                    right = parentRight
                }

                var rcChild = NSRect.zero
                if horizontalRows {
                    rcChild.origin.x = CGFloat(left)
                    rcChild.origin.y = CGFloat(top)
                    rcChild.size.width = CGFloat(right - left)
                    rcChild.size.height = CGFloat(bottom - top)
                } else {
                    rcChild.origin.x = CGFloat(top)
                    rcChild.origin.y = CGFloat(left)
                    rcChild.size.width = CGFloat(bottom - top)
                    rcChild.size.height = CGFloat(right - left)
                }

                childRenderers[childIndex].calcLayout(rcChild)

                left = right
                childIndex += 1
            }

            top = bottom
        }
    }

    private func arrangeChildsOnRows(rows: inout [Double],
                                     childsPerRow: inout [Int],
                                     childWidths: inout [Double],
                                     rowsAreHoriz horizontal: inout Bool) {
        let childCount = _childRenderers?.count ?? 0

        if weight() == 0 {
            rows.append(1)
            childsPerRow.append(childCount)

            let standardWidth = 1.0 / Double(childCount)
            for _ in 0..<childCount {
                childWidths.append(standardWidth)
            }

            horizontal = true
        } else {
            horizontal = _rect.size.width >= _rect.size.height

            var width = 1.0
            if horizontal {
                if _rect.size.height > 0 {
                    width = Double(_rect.size.width) / Double(_rect.size.height)
                }
            } else {
                if _rect.size.width > 0 {
                    width = Double(_rect.size.height) / Double(_rect.size.width)
                }
            }

            var i = 0
            while i < childCount {
                var childsUsed = 0
                let rowHeight = calculateRow(startChildIndex: i, rowWidth: width,
                                             childsUsed: &childsUsed, childWidths: &childWidths)
                rows.append(rowHeight)
                childsPerRow.append(childsUsed)
                i += childsUsed
            }
        }
    }

    private func calculateRow(startChildIndex: Int, rowWidth: Double,
                              childsUsed: inout Int, childWidths: inout [Double]) -> Double {
        let minProportion = 0.4
        let mySize = Double(weight())
        let childRenderers = _childRenderers ?? []
        let childCount = childRenderers.count

        var sizeUsed = 0.0
        var rowHeight = 0.0

        childsUsed = 0

        var i = startChildIndex
        while i < childCount {
            let childSize = Double(childRenderers[i].weight())
            if childSize == 0 {
                assert(i > startChildIndex, "first child must not have size of 0")
                break
            }

            sizeUsed += childSize
            let virtualRowHeight = sizeUsed / mySize
            assert(virtualRowHeight > 0 && virtualRowHeight <= 1,
                   "incorrect calculated parent size ( sum(childs) > parent )")

            let childWidth = childSize / mySize * rowWidth / virtualRowHeight

            if childWidth / virtualRowHeight < minProportion {
                assert(i > startChildIndex, "")
                break
            }
            rowHeight = virtualRowHeight
            i += 1
        }
        assert(i > startChildIndex, "row calculation aborted")

        // Now i-1 is the last child used and rowHeight is the height of the row.

        // We add the rest of the zero-sized childs
        while i < childCount && childRenderers[i].weight() == 0 {
            i += 1
        }

        childsUsed = i - startChildIndex

        // Rectangle(1.0 * 1.0) = mySize
        let rowSize = mySize * rowHeight

        // Now as we know the rowHeight, we compute the widths of our children.
        for j in 0..<childsUsed {
            let childSize = Double(childRenderers[startChildIndex + j].weight())
            let cw = childSize / rowSize
            childWidths.append(cw)
        }

        return rowHeight
    }

    private func createChildRenderers() {
        guard let ds = dataSource else { return }
        let childCount = Int(ds.treeMapView!(_view, numberOfChildrenOfItem: _item))

        if _childRenderers == nil {
            _childRenderers = []
            _childRenderers!.reserveCapacity(childCount)
        }

        var existingRendererCount = _childRenderers!.count

        // delete supernumerary renderers
        if existingRendererCount > childCount {
            _childRenderers!.removeLast(existingRendererCount - childCount)
            existingRendererCount = childCount
        }

        // init renderers
        for i in 0..<childCount {
            let childItem = ds.treeMapView!(_view, child: UInt(i), ofItem: _item)
            assert(childItem != nil, "data source returned nil as child item")

            if i < existingRendererCount {
                // recycle existing renderer
                _childRenderers![i].refresh(withItem: childItem)
            } else {
                let childRenderer = TMVItem(dataSource: _dataSource, delegate: _delegate,
                                            renderedItem: childItem, treeMapView: _view)
                _childRenderers!.append(childRenderer)
            }
        }
    }
}
