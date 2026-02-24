//
//  TreeMapLayout.swift
//  DiskInventoryX
//
//  TreeMap layout algorithm - ported from original TMVItem.m
//  Uses row-based layout with minProportion constraint
//

import SwiftUI

struct TreeMapRect {
    let node: FileNode
    var rect: CGRect
    let color: Color
    let depth: Int  // Nesting depth for cushion shading
}

enum TreeMapLayout {

    /// Minimum aspect ratio for rectangles (prevents very thin rectangles)
    private static let minProportion: Double = 0.4

    /// Calculates treemap layout for the given node and its children
    static func layout(
        node: FileNode,
        rect: CGRect,
        colorProvider: (String) -> Color,
        depth: Int = 0,
        maxDepth: Int = 8
    ) -> [TreeMapRect] {
        var results: [TreeMapRect] = []

        let children = node.children.filter { $0.size > 0 }

        // If no children or at max depth, this is a leaf
        guard !children.isEmpty, depth < maxDepth else {
            if rect.width >= 1 && rect.height >= 1 {
                results.append(TreeMapRect(
                    node: node,
                    rect: rect,
                    color: colorProvider(node.kindName),
                    depth: depth
                ))
            }
            return results
        }

        // Sort children by size (largest first) - critical for the algorithm
        let sorted = children.sorted { $0.size > $1.size }
        let totalWeight = Double(node.size)

        guard totalWeight > 0 else { return results }

        // Determine if rows should be horizontal or vertical
        let horizontal = rect.width >= rect.height

        // Calculate normalized width (aspect ratio)
        let width: Double
        if horizontal {
            width = rect.height > 0 ? Double(rect.width) / Double(rect.height) : 1.0
        } else {
            width = rect.width > 0 ? Double(rect.height) / Double(rect.width) : 1.0
        }

        // Arrange children into rows
        var rows: [(height: Double, children: [(node: FileNode, width: Double)])] = []
        var childIndex = 0

        while childIndex < sorted.count {
            let (rowHeight, childWidths, childsUsed) = calculateRow(
                children: sorted,
                startIndex: childIndex,
                rowWidth: width,
                totalWeight: totalWeight
            )

            if childsUsed == 0 { break }

            var rowChildren: [(node: FileNode, width: Double)] = []
            for i in 0..<childsUsed {
                rowChildren.append((sorted[childIndex + i], childWidths[i]))
            }

            rows.append((rowHeight, rowChildren))
            childIndex += childsUsed
        }

        // Layout the rows
        let parentWidth = horizontal ? rect.width : rect.height
        let parentHeight = horizontal ? rect.height : rect.width
        let parentLeft = horizontal ? rect.minX : rect.minY
        let parentTop = horizontal ? rect.minY : rect.minX
        let parentRight = horizontal ? rect.maxX : rect.maxY
        let parentBottom = horizontal ? rect.maxY : rect.maxX

        var top = parentTop

        for (rowIndex, row) in rows.enumerated() {
            var bottom = top + CGFloat(row.height) * parentHeight

            // Last row: snap to parent bottom to avoid rounding errors
            if bottom > parentBottom || rowIndex == rows.count - 1 {
                bottom = parentBottom
            }

            var left = parentLeft

            for (colIndex, child) in row.children.enumerated() {
                var right = left + CGFloat(child.width) * parentWidth

                // Last column: snap to parent right
                if right > parentRight || colIndex == row.children.count - 1 {
                    right = parentRight
                }

                let childRect: CGRect
                if horizontal {
                    childRect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                } else {
                    childRect = CGRect(x: top, y: left, width: bottom - top, height: right - left)
                }

                // Skip very small rectangles
                if childRect.width >= 2 && childRect.height >= 2 {
                    // Recursively layout children if this is a directory
                    if child.node.isDirectory && !child.node.children.isEmpty {
                        let childRects = layout(
                            node: child.node,
                            rect: childRect.insetBy(dx: 1, dy: 1),
                            colorProvider: colorProvider,
                            depth: depth + 1,
                            maxDepth: maxDepth
                        )
                        results.append(contentsOf: childRects)
                    } else {
                        results.append(TreeMapRect(
                            node: child.node,
                            rect: childRect,
                            color: colorProvider(child.node.kindName),
                            depth: depth + 1
                        ))
                    }
                }

                left = right
            }

            top = bottom
        }

        return results
    }

    /// Calculate a single row of children
    /// Returns: (rowHeight as fraction, childWidths as fractions, number of children used)
    private static func calculateRow(
        children: [FileNode],
        startIndex: Int,
        rowWidth: Double,
        totalWeight: Double
    ) -> (Double, [Double], Int) {

        var sizeUsed: Double = 0
        var rowHeight: Double = 0
        var childWidths: [Double] = []
        var childsUsed = 0

        for i in startIndex..<children.count {
            let childSize = Double(children[i].size)

            // Skip zero-size children (they'll be added at the end)
            if childSize == 0 {
                if i > startIndex {
                    break
                }
                continue
            }

            sizeUsed += childSize
            let virtualRowHeight = sizeUsed / totalWeight

            // Rectangle(totalWeight) = width * 1.0
            // Rectangle(childSize) = childWidth * virtualRowHeight
            // childWidth = childSize / totalWeight * rowWidth / virtualRowHeight
            let childWidth = childSize / totalWeight * rowWidth / virtualRowHeight

            // Stop if rectangle would be too thin
            if childWidth / virtualRowHeight < minProportion {
                if i > startIndex {
                    break
                }
                // First child - must include it
            }

            rowHeight = virtualRowHeight
            childsUsed = i - startIndex + 1
        }

        // Add any remaining zero-size children
        var i = startIndex + childsUsed
        while i < children.count && children[i].size == 0 {
            childsUsed += 1
            i += 1
        }

        // Calculate final child widths
        let rowSize = totalWeight * rowHeight
        for j in 0..<childsUsed {
            let childSize = Double(children[startIndex + j].size)
            let cw = rowSize > 0 ? childSize / rowSize : 1.0 / Double(childsUsed)
            childWidths.append(cw)
        }

        return (rowHeight, childWidths, childsUsed)
    }
}
