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

// Children whose cell would be smaller than this many square points are not
// drawn individually; a folder's small children are merged into one "small
// items" cell instead. Without this, folders with thousands of tiny files turn
// into speckle (and sub-point cells are skipped entirely, leaving black holes).
// Overridable via the "TreeMapMinimumCellArea" user default (0 = off).
private let defaultMinimumCellArea: Double = 16   // ~4 x 4 pt
private let minimumCellAreaDefaultsKey = "TreeMapMinimumCellArea"

// Fallback color for a merged small-items cell when the delegate gives none;
// normally it takes the color of its largest merged file, drawn flat and dimmed.
private let smallItemsColor: NSColor =
    TMVCushionRenderer.normalize(NSColor(calibratedWhite: 0.45, alpha: 1))

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

    // Small-item merging (see defaultMinimumCellArea).
    // _laidOutRenderers: the cells actually laid out/drawn/hit-tested for this
    // node: the children big enough to show, plus _smallItemsRenderer if any
    // children were merged. nil until the first layout.
    private var _laidOutRenderers: [TMVItem]?
    // synthetic leaf standing for this node's merged small children; its item
    // is this node's item (so hovering/clicking it refers to the folder)
    private var _smallItemsRenderer: TMVItem?
    // set on a child that was merged into its parent's small-items cell
    private(set) var isMergedIntoParent = false
    // non-nil only for a small-items renderer: the summed weight it stands for
    private var _aggregateWeight: UInt64?
    private var _aggregateCount = 0
    // for a small-items cell: the item of its largest merged file, whose color
    // the cell takes (so a folder of tiny .js files stays the .js color)
    private var _representativeItem: Any?

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

    // creates a small-items renderer: a leaf representing `count` merged
    // children of `parent`, with their summed weight
    private init(smallItemsOf parent: TMVItem, weight: UInt64, count: Int) {
        _item = parent._item
        _dataSource = parent._dataSource
        _delegate = parent._delegate
        _view = parent._view
        _rect = .zero
        _cushionRenderer = TMVCushionRenderer()
        _aggregateWeight = weight
        _aggregateCount = count
        super.init()
        _cushionRenderer.setColor(smallItemsColor)
    }

    // true for the synthetic cell standing for a folder's merged small children
    @objc
    var isSmallItemsCell: Bool {
        _aggregateWeight != nil
    }

    // number of children merged into this small-items cell (0 for regular cells)
    @objc
    var mergedItemCount: Int {
        _aggregateCount
    }

    // the small-items cell this node's merged children were folded into, if any
    var smallItemsRenderer: TMVItem? {
        _smallItemsRenderer
    }

    @objc(refreshWithItem:)
    func refresh(withItem item: Any?) {
        _item = item
        _rect = .zero
        _cushionRenderer.setRect(.zero)
        _laidOutRenderers = nil
        _smallItemsRenderer = nil
        isMergedIntoParent = false

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
            for childRenderer in laidOutRenderers {
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
        if isSmallItemsCell { return true }
        guard let ds = dataSource else { return true }
        return !(ds.treeMapView!(_view, isNode: _item))
    }

    @objc
    func item() -> Any? {
        _item
    }

    @objc
    func weight() -> UInt64 {
        if let aggregateWeight = _aggregateWeight { return aggregateWeight }
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
            for childRenderer in laidOutRenderers {
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
            let colorItem = isSmallItemsCell ? _representativeItem : _item
            if isSmallItemsCell {
                _cushionRenderer.setColor(smallItemsColor)
            }
            if colorItem != nil || !isSmallItemsCell, let delegate = delegate,
               (_delegate?.responds(to: #selector(TreeMapViewDelegate.treeMapView(_:willDisplayItem:withRenderer:))) ?? false) {
                delegate.treeMapView!(_view, willDisplayItem: colorItem, withRenderer: self)
            }

            if isSmallItemsCell {
                // flat, without a cushion, so it reads as a group rather than one file
                _cushionRenderer.renderFlat(inBitmap: bitmap)
            } else {
                _cushionRenderer.renderCushion(inBitmap: bitmap)
            }
        } else {
            for child in laidOutRenderers {
                child.drawCushion(inBitmap: bitmap,
                                  parentCushion: _cushionRenderer,
                                  cushionHeightFactor: heightFactor * CUSHION_SCALE_FACTOR)
            }
        }
    }

    // the cells laid out, drawn and hit-tested for this node
    private var laidOutRenderers: [TMVItem] {
        _laidOutRenderers ?? _childRenderers ?? []
    }

    private static func minimumCellArea() -> Double {
        if UserDefaults.standard.object(forKey: minimumCellAreaDefaultsKey) != nil {
            return max(0, UserDefaults.standard.double(forKey: minimumCellAreaDefaultsKey))
        }
        return defaultMinimumCellArea
    }

    // the heaviest file among `renderers` and their descendants, following
    // each folder's largest child (children are sorted by size, descending)
    private static func largestLeaf(among renderers: [TMVItem]) -> TMVItem? {
        guard var candidate = renderers.max(by: { $0.weight() < $1.weight() }) else {
            return nil
        }
        while !candidate.isLeaf() {
            guard let next = candidate._childRenderers?.max(by: { $0.weight() < $1.weight() }) else {
                return nil
            }
            candidate = next
        }
        return candidate
    }

    // drops this renderer (a merged child) out of the layout
    private func markMergedIntoParent() {
        isMergedIntoParent = true
        _rect = .zero
        _cushionRenderer.setRect(.zero)
    }

    // Splits the children into those big enough to get their own cell and the
    // rest, which are merged into one small-items cell. Children are sorted by
    // size descending, so the merged ones are (nearly always) the tail.
    private func computeLaidOutRenderers(_ childRenderers: [TMVItem]) -> [TMVItem] {
        let minArea = TMVItem.minimumCellArea()
        let totalWeight = Double(weight())
        guard minArea > 0, totalWeight > 0, childRenderers.count > 1 else {
            return childRenderers
        }

        // area of this cell in points (cells are in backing pixels)
        let rectPoints = _view?.convertRectFromBackingRespectingFlipped(_rect) ?? _rect
        let areaPoints = Double(rectPoints.width) * Double(rectPoints.height)

        var shown: [TMVItem] = []
        var merged: [TMVItem] = []
        var mergedWeight: UInt64 = 0
        for child in childRenderers {
            let childWeight = child.weight()
            if areaPoints * Double(childWeight) / totalWeight < minArea {
                merged.append(child)
                mergedWeight += childWeight
            } else {
                shown.append(child)
            }
        }

        // merging a single child gains nothing; keep it as it is
        if merged.count < 2 {
            return childRenderers
        }

        for child in shown {
            child.isMergedIntoParent = false
        }
        for child in merged {
            child.markMergedIntoParent()
        }

        let smallItems: TMVItem
        if let existing = _smallItemsRenderer {
            existing._aggregateWeight = mergedWeight
            existing._aggregateCount = merged.count
            smallItems = existing
        } else {
            smallItems = TMVItem(smallItemsOf: self, weight: mergedWeight, count: merged.count)
            _smallItemsRenderer = smallItems
        }
        // force the cell to take its new rect even if the size is unchanged
        smallItems._rect = .zero
        smallItems._representativeItem = TMVItem.largestLeaf(among: merged)?._item

        // keep the cell list sorted by weight (descending), as the
        // squarified layout expects
        let insertIndex = shown.firstIndex { $0.weight() < mergedWeight } ?? shown.count
        shown.insert(smallItems, at: insertIndex)
        return shown
    }

    private func layoutChilds() {
        guard let allChildRenderers = _childRenderers else { return }

        let childRenderers = computeLaidOutRenderers(allChildRenderers)
        if childRenderers.count == allChildRenderers.count {
            // nothing merged
            _smallItemsRenderer = nil
            _laidOutRenderers = nil
            for child in allChildRenderers where child.isMergedIntoParent {
                child.isMergedIntoParent = false
            }
        } else {
            _laidOutRenderers = childRenderers
        }

        var rows: [Double] = []              // fraction of total height for each row
        var childsPerRow: [Int] = []         // number of childs per row
        var childWidths: [Double] = []       // fraction of total width for each child

        var horizontalRows = false
        arrangeChildsOnRows(childRenderers, rows: &rows, childsPerRow: &childsPerRow,
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

    private func arrangeChildsOnRows(_ childRenderers: [TMVItem],
                                     rows: inout [Double],
                                     childsPerRow: inout [Int],
                                     childWidths: inout [Double],
                                     rowsAreHoriz horizontal: inout Bool) {
        let childCount = childRenderers.count

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
                let rowHeight = calculateRow(childRenderers, startChildIndex: i, rowWidth: width,
                                             childsUsed: &childsUsed, childWidths: &childWidths)
                rows.append(rowHeight)
                childsPerRow.append(childsUsed)
                i += childsUsed
            }
        }
    }

    private func calculateRow(_ childRenderers: [TMVItem], startChildIndex: Int, rowWidth: Double,
                              childsUsed: inout Int, childWidths: inout [Double]) -> Double {
        let minProportion = 0.4
        let mySize = Double(weight())
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
