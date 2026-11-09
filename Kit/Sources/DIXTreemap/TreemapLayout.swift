//
//  TreemapLayout.swift
//  DIXTreemap
//
//  The original squarified layout (TMVItem.layoutChilds / arrangeChildsOnRows /
//  calculateRow on origin/master): rows of children, minProportion 0.4, rows
//  horizontal when the cell is wider than high, the row aspect measured against
//  the whole cell. Kept as is, with these fixes:
//
//  - Edges are rounded from cumulative fractions, not incrementally, so no
//    cell drifts more than half a pixel per edge and the last one doesn't
//    absorb the error.
//  - Every cell with pixels is drawn (the original skipped cells under 1 pt,
//    leaving black holes), and the children always tile their parent exactly.
//  - A folder's children too small to see (under `minimumCellArea`) are not
//    drawn one by one but merged. The layout is computed with all children,
//    exactly as the original does, and the merged children's rects are then
//    joined: the tail of a row becomes one cell and the rows after it another.
//    So every visible cell sits exactly where the original puts it.
//  - Zero-size children and children not summing to their parent don't trap.
//
//  Layout works in backing pixels; `scale` converts point-based thresholds.
//
//  GPL v3
//

import DIXCore

public struct TreemapOptions: Sendable, Hashable {
    /// children whose cell would be smaller than this (in square points) are
    /// merged into one cell per run; 0 turns merging off
    public var minimumCellArea: Double
    /// add the volume's free space as a cell of the layout root
    public var showFreeSpace: Bool
    /// add the volume's other used space (not in the snapshot) as a cell of the layout root
    public var showOtherSpace: Bool
    public var mergedCellStyle: MergedCellStyle
    /// Round edges incrementally like the original (drifting; the last child
    /// absorbs the error). Only for measuring the shader against the original
    /// renderer: with this and merging off, the output is pixel-identical.
    public var originalRounding: Bool

    public init(minimumCellArea: Double = 16, showFreeSpace: Bool = false, showOtherSpace: Bool = false,
                mergedCellStyle: MergedCellStyle = .cushion, originalRounding: Bool = false) {
        self.minimumCellArea = minimumCellArea
        self.showFreeSpace = showFreeSpace
        self.showOtherSpace = showOtherSpace
        self.mergedCellStyle = mergedCellStyle
        self.originalRounding = originalRounding
    }
}

/// How a merged cell (many small items) is shaded.
public enum MergedCellStyle: String, Sendable, Hashable, CaseIterable {
    /// its own cushion, like a file, in the color of the merged items' dominant kind
    case cushion
    /// no cushion of its own: it continues its folder's cushion, in the dominant kind's color
    case folderSurface
}

/// An integer rectangle in backing pixels, origin top left.
public struct PixelRect: Sendable, Hashable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var area: Int { width * height }

    public func contains(x px: Int, y py: Int) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }

    public var description: String { "(\(x),\(y) \(width)x\(height))" }
}

/// One cell of a layout.
public struct TreemapCell: Sendable, Hashable {
    public enum Role: UInt8, Sendable, Hashable {
        /// a folder (or shown package) whose children are cells of their own
        case container
        /// a file, or a folder/package drawn as one cell
        case item
        /// several small items of one folder, merged
        case merged
        case freeSpace
        case otherSpace
    }

    public var rect: PixelRect
    public var role: Role
    /// the item; for a merged cell, the folder whose children were merged; for
    /// free/other space, the layout root
    public var node: NodeIndex
    /// containing cell (-1 for the root cell)
    public var parent: Int
    /// child cells (containers only)
    public var children: Range<Int>
    /// 0 for the root cell
    public var depth: Int
    /// index into `TreemapLayout.mergedGroups` (merged cells only)
    public var mergedGroup: Int?
}

/// The children of one folder merged into one cell.
public struct MergedGroup: Sendable, Hashable {
    /// the folder they belong to
    public var folder: NodeIndex
    /// how many of its children the cell stands for
    public var count: Int
    /// their total size, in the layout's size mode
    public var size: UInt64
    /// the kind holding most of their bytes (the cell's color)
    public var dominantKind: Int
    /// fraction of their bytes that are cloud placeholders (logical mode)
    public var cloudFraction: Double
    /// the cell drawing them
    public var cell: Int
    /// range into `TreemapLayout.mergedMembers`
    public var members: Range<Int>
}

/// What is under a point.
public enum TreemapHit: Sendable, Hashable {
    /// a file, or a folder or package drawn as one cell
    case node(NodeIndex, cell: Int)
    /// a merged cell of small items
    case merged(MergedGroup)
    case freeSpace(cell: Int)
    case otherSpace(cell: Int)

    public var cell: Int {
        switch self {
        case .node(_, let cell), .freeSpace(let cell), .otherSpace(let cell): return cell
        case .merged(let group): return group.cell
        }
    }
}

/// Internal per-cell data, compact.
struct CellData {
    var x0: Int32, y0: Int32, x1: Int32, y1: Int32
    var node: Int32
    var parent: Int32
    var firstChild: Int32
    var childCount: Int32
    var group: Int32          // merged group or -1
    var colorKind: Int32      // kind index for the color, -1 = grey
    var depth: UInt16
    var role: TreemapCell.Role
    var cloud: Bool
    var heightFactor: Float
    var surface: CushionSurface
}

public struct TreemapLayout: Sendable {
    public let model: TreemapModel
    public let root: NodeIndex
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scale: Double
    public let options: TreemapOptions

    var cellData: [CellData] = []
    public private(set) var mergedGroups: [MergedGroup] = []
    /// node indexes of merged children, sliced by `MergedGroup.members`
    public private(set) var mergedMembers: [UInt32] = []

    public var cellCount: Int { cellData.count }

    public func cell(_ index: Int) -> TreemapCell {
        let c = cellData[index]
        return TreemapCell(rect: PixelRect(x: Int(c.x0), y: Int(c.y0), width: Int(c.x1 - c.x0), height: Int(c.y1 - c.y0)),
                           role: c.role, node: Int(c.node), parent: Int(c.parent),
                           children: Int(c.firstChild) ..< Int(c.firstChild + c.childCount),
                           depth: Int(c.depth), mergedGroup: c.group >= 0 ? Int(c.group) : nil)
    }

    public var cells: [TreemapCell] { (0 ..< cellData.count).map(cell) }

    /// indexes of the cells that are drawn (everything but containers)
    public var drawnCells: [Int] {
        cellData.indices.filter { cellData[$0].role != .container }
    }

    public func mergedMembers(of group: MergedGroup) -> [NodeIndex] {
        mergedMembers[group.members].map { Int($0) }
    }

    init(model: TreemapModel, root: NodeIndex, pixelWidth: Int, pixelHeight: Int, scale: Double, options: TreemapOptions) {
        self.model = model
        self.root = (root >= 0 && root < model.snapshot.nodeCount) ? root : Snapshot.root
        self.pixelWidth = max(0, pixelWidth)
        self.pixelHeight = max(0, pixelHeight)
        self.scale = scale > 0 ? scale : 1
        self.options = options
        build()
    }

    // MARK: - building

    private struct Item {
        var node: Int32       // -1 other space, -2 free space
        var weight: UInt64
    }

    private mutating func build() {
        let snapshot = model.snapshot
        let rootIsContainer = model.isContainer(root, isLayoutRoot: true)
        cellData.reserveCapacity(1024)
        cellData.append(CellData(x0: 0, y0: 0, x1: Int32(pixelWidth), y1: Int32(pixelHeight),
                                 node: Int32(root), parent: -1, firstChild: 0, childCount: 0, group: -1,
                                 colorKind: Int32(snapshot.kindIndex[root]), depth: 0,
                                 role: rootIsContainer ? .container : .item,
                                 cloud: model.sizeMode == .logical && snapshot.flags[root].contains(.cloudPlaceholder),
                                 heightFactor: CushionMath.rootHeightFactor, surface: CushionSurface()))
        guard pixelWidth > 0, pixelHeight > 0 else { return }

        var items: [Item] = []
        var widths: [Double] = []
        var kindAcc = [UInt64](repeating: 0, count: max(1, snapshot.kinds.count))
        var touched: [Int] = []
        let minAreaPx = max(0, options.minimumCellArea) * scale * scale

        var index = 0
        while index < cellData.count {
            if cellData[index].role == .container {
                layoutChildren(of: index, items: &items, widths: &widths, minAreaPx: minAreaPx,
                               kindAcc: &kindAcc, touched: &touched)
            }
            index += 1
        }
    }

    private mutating func layoutChildren(of cellIndex: Int, items: inout [Item], widths: inout [Double],
                                         minAreaPx: Double, kindAcc: inout [UInt64], touched: inout [Int]) {
        let parent = cellData[cellIndex]
        let snapshot = model.snapshot
        let node = Int(parent.node)

        items.removeAll(keepingCapacity: true)
        let range = TreemapModel.childRange(snapshot, node)
        let sizes = model.sizes
        for position in range {
            let child = model.child(position)
            items.append(Item(node: Int32(child), weight: sizes[child]))
        }
        let realCount = items.count
        if cellIndex == 0, let volume = snapshot.volume {
            let rootSize = sizes[node]
            if options.showOtherSpace {
                let used = volume.totalCapacity &- min(volume.availableCapacity, volume.totalCapacity)
                items.append(Item(node: -1, weight: used > rootSize ? used - rootSize : 0))
            }
            if options.showFreeSpace {
                items.append(Item(node: -2, weight: volume.availableCapacity))
            }
        }
        guard !items.isEmpty else { return }

        var total = 0.0
        for item in items { total += Double(item.weight) }

        let x0 = Int(parent.x0), y0 = Int(parent.y0), x1 = Int(parent.x1), y1 = Int(parent.y1)
        let rectW = x1 - x0, rectH = y1 - y0
        let area = Double(rectW) * Double(rectH)

        // the merged tail: trailing real children whose cell would be too small
        var mergeStart = realCount
        if minAreaPx > 0 && total > 0 {
            let threshold = minAreaPx * total / area
            while mergeStart > 0 && Double(items[mergeStart - 1].weight) < threshold {
                mergeStart -= 1
            }
        }

        let horizontal: Bool
        var rowWidth = 1.0
        if total == 0 {
            horizontal = true
        } else {
            horizontal = rectW >= rectH
            if horizontal {
                if rectH > 0 { rowWidth = Double(rectW) / Double(rectH) }
            } else {
                if rectW > 0 { rowWidth = Double(rectH) / Double(rectW) }
            }
        }

        let parentWidth = Double(horizontal ? rectW : rectH)
        let parentHeight = Double(horizontal ? rectH : rectW)
        let left0 = horizontal ? x0 : y0
        let right0 = horizontal ? x1 : y1
        let top0 = horizontal ? y0 : x0
        let bottom0 = horizontal ? y1 : x1

        let childHF = parent.heightFactor * CushionMath.heightScale
        let firstChildCell = cellData.count
        let hasSpecials = realCount < items.count

        // emits one cell; `a..<b` along the rows' width, `t..<u` along their height
        func emit(_ layout: inout TreemapLayout, a: Int, b: Int, t: Int, u: Int, item: Int, group: Int32) {
            let cx0: Int, cx1: Int, cy0: Int, cy1: Int
            if horizontal { cx0 = a; cx1 = b; cy0 = t; cy1 = u } else { cx0 = t; cx1 = u; cy0 = a; cy1 = b }
            guard cx1 > cx0, cy1 > cy0 else { return }
            var surface = parent.surface
            var role: TreemapCell.Role
            var colorKind: Int32 = -1
            var cloud = false
            var nodeIndex = Int32(node)
            if group >= 0 {
                role = .merged
                colorKind = Int32(layout.mergedGroups[Int(group)].dominantKind)
                cloud = layout.mergedGroups[Int(group)].cloudFraction > 0.5
                if layout.options.mergedCellStyle == .cushion {
                    surface.addRidge(x0: cx0, y0: cy0, x1: cx1, y1: cy1, heightFactor: childHF)
                }
            } else {
                let it = items[item]
                if it.node == -1 {
                    role = .otherSpace
                } else if it.node == -2 {
                    role = .freeSpace
                } else {
                    nodeIndex = it.node
                    let n = Int(it.node)
                    role = layout.model.isContainer(n) ? .container : .item
                    colorKind = Int32(snapshot.kindIndex[n])
                    cloud = layout.model.sizeMode == .logical && snapshot.flags[n].contains(.cloudPlaceholder)
                }
                surface.addRidge(x0: cx0, y0: cy0, x1: cx1, y1: cy1, heightFactor: childHF)
            }
            if group >= 0 { layout.mergedGroups[Int(group)].cell = layout.cellData.count }
            layout.cellData.append(CellData(x0: Int32(cx0), y0: Int32(cy0), x1: Int32(cx1), y1: Int32(cy1),
                                            node: nodeIndex, parent: Int32(cellIndex), firstChild: 0, childCount: 0,
                                            group: group, colorKind: colorKind,
                                            depth: parent.depth &+ 1, role: role, cloud: cloud,
                                            heightFactor: childHF, surface: surface))
        }

        // emits the merged children items[first..<end] as one cell (or as
        // themselves when it is just one)
        func emitRun(_ layout: inout TreemapLayout, a: Int, b: Int, t: Int, u: Int, first: Int, end: Int) {
            guard end > first else { return }
            if end - first == 1 {
                emit(&layout, a: a, b: b, t: t, u: u, item: first, group: -1)
                return
            }
            guard b > a, u > t else { return }
            let memberStart = layout.mergedMembers.count
            var size: UInt64 = 0
            var cloudBytes: UInt64 = 0
            touched.removeAll(keepingCapacity: true)
            let rep = layout.model.representativeKind
            for i in first ..< end {
                let n = Int(items[i].node)
                layout.mergedMembers.append(UInt32(n))
                size &+= items[i].weight
                if !layout.model.cloudBytes.isEmpty { cloudBytes &+= layout.model.cloudBytes[n] }
                let k = Int(rep[n])
                if k < kindAcc.count {
                    if kindAcc[k] == 0 { touched.append(k) }
                    kindAcc[k] &+= max(items[i].weight, 1)
                }
            }
            let best = layout.model.kindColors.dominantKind(touched, &kindAcc, fallback: -1)
            let group = MergedGroup(folder: node, count: end - first, size: size, dominantKind: best,
                                    cloudFraction: size > 0 ? Double(cloudBytes) / Double(size) : 0,
                                    cell: -1, members: memberStart ..< layout.mergedMembers.count)
            layout.mergedGroups.append(group)
            emit(&layout, a: a, b: b, t: t, u: u, item: first, group: Int32(layout.mergedGroups.count - 1))
        }

        var start = 0
        var cumRow = 0.0
        var top = top0
        var blockTop = -1, blockFirst = -1

        while start < items.count {
            if start >= mergeStart && !hasSpecials {
                // everything from here on is merged: the remaining rows form one block
                if blockFirst < 0 { blockTop = top; blockFirst = start }
                start = items.count
                break
            }

            // one row (TMVItem.calculateRow)
            widths.removeAll(keepingCapacity: true)
            var used = 0
            var rowHeight = 0.0
            if total == 0 {
                used = items.count
                rowHeight = 1
                for _ in 0 ..< used { widths.append(1.0 / Double(used)) }
            } else {
                var sizeUsed = 0.0
                var i = start
                while i < items.count {
                    let childSize = Double(items[i].weight)
                    if childSize == 0 { break }
                    sizeUsed += childSize
                    let virtualRowHeight = sizeUsed / total
                    let childWidth = childSize / total * rowWidth / virtualRowHeight
                    if childWidth / virtualRowHeight < 0.4 && i > start { break }
                    rowHeight = virtualRowHeight
                    i += 1
                }
                // the rest of the zero-sized children join this row
                while i < items.count && items[i].weight == 0 { i += 1 }
                used = max(1, i - start)
                let rowSize = total * rowHeight
                for j in 0 ..< used {
                    widths.append(rowSize > 0 ? Double(items[start + j].weight) / rowSize : 1.0 / Double(used))
                }
            }

            cumRow += rowHeight
            let isLastRow = start + used >= items.count
            var bottom = isLastRow ? bottom0
                : options.originalRounding ? top + Int((rowHeight * parentHeight).rounded())
                : top0 + Int((cumRow * parentHeight).rounded())
            bottom = min(max(bottom, top), bottom0)

            let rowEnd = start + used
            if start >= mergeStart && rowEnd <= realCount {
                // the whole row is merged: it joins the block
                if blockFirst < 0 { blockTop = top; blockFirst = start }
            } else {
                if blockFirst >= 0 {
                    emitRun(&self, a: left0, b: right0, t: blockTop, u: top, first: blockFirst, end: start)
                    blockFirst = -1
                }
                var cum = 0.0
                var left = left0
                var runLeft = -1, runFirst = -1
                for j in 0 ..< used {
                    cum += widths[j]
                    var right = j == used - 1 ? right0
                        : options.originalRounding ? left + Int((widths[j] * parentWidth).rounded())
                        : left0 + Int((cum * parentWidth).rounded())
                    right = min(max(right, left), right0)
                    let position = start + j
                    if position >= mergeStart && position < realCount {
                        if runFirst < 0 { runFirst = position; runLeft = left }
                    } else {
                        if runFirst >= 0 {
                            emitRun(&self, a: runLeft, b: left, t: top, u: bottom, first: runFirst, end: position)
                            runFirst = -1
                        }
                        emit(&self, a: left, b: right, t: top, u: bottom, item: position, group: -1)
                    }
                    left = right
                }
                if runFirst >= 0 {
                    emitRun(&self, a: runLeft, b: right0, t: top, u: bottom, first: runFirst, end: rowEnd)
                }
            }
            top = bottom
            start = rowEnd
        }
        if blockFirst >= 0 {
            emitRun(&self, a: left0, b: right0, t: blockTop, u: bottom0, first: blockFirst, end: min(items.count, realCount))
        }

        cellData[cellIndex].firstChild = Int32(firstChildCell)
        cellData[cellIndex].childCount = Int32(cellData.count - firstChildCell)
        if cellData[cellIndex].childCount == 0 {
            // nothing got pixels (can't happen for a valid snapshot): draw it as one cell
            cellData[cellIndex].role = .item
        }
    }
}
