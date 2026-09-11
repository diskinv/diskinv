import CoreGraphics
import Foundation

struct TreeMapRect: Sendable {
  let node: FileNode
  let rect: CGRect
  let depth: Int
}

enum TreeMapLayout {
  private static let minimumAspectRatio = 0.4

  static func layout(
    node: FileNode,
    in rect: CGRect,
    showPackageContents: Bool,
    pixelScale: CGFloat = 1
  ) -> [TreeMapRect] {
    let scale = max(1, pixelScale)
    let minX = (rect.minX * scale).rounded()
    let minY = (rect.minY * scale).rounded()
    let maxX = (rect.maxX * scale).rounded()
    let maxY = (rect.maxY * scale).rounded()
    let pixelRectangles = layoutNode(
      node: node,
      in: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
      showPackageContents: showPackageContents,
      depth: 0
    )
    guard scale != 1 else { return pixelRectangles }
    return pixelRectangles.map {
      TreeMapRect(
        node: $0.node,
        rect: CGRect(
          x: $0.rect.minX / scale,
          y: $0.rect.minY / scale,
          width: $0.rect.width / scale,
          height: $0.rect.height / scale
        ),
        depth: $0.depth
      )
    }
  }

  static func rectangle(at point: CGPoint, in rectangles: [TreeMapRect]) -> TreeMapRect? {
    rectangles.last { $0.rect.contains(point) }
  }

  private static func layoutNode(
    node: FileNode,
    in rect: CGRect,
    showPackageContents: Bool,
    depth: Int
  ) -> [TreeMapRect] {
    guard !Task.isCancelled, rect.width >= 1, rect.height >= 1 else { return [] }
    let children = node.children.filter { $0.size > 0 }
    let isLeaf = !node.isDirectory || node.isPackage && !showPackageContents

    guard !isLeaf, !children.isEmpty else {
      return [TreeMapRect(node: node, rect: rect, depth: depth)]
    }

    let total = children.reduce(UInt64(0)) { $0.saturatingAdding($1.size) }
    guard total > 0 else { return [] }

    let horizontal = rect.width >= rect.height
    let longSide = horizontal ? rect.width : rect.height
    let shortSide = horizontal ? rect.height : rect.width
    let normalizedWidth = shortSide > 0 ? Double(longSide / shortSide) : 1
    var rows: [(height: Double, children: ArraySlice<FileNode>, widths: [Double])] = []
    var index = 0

    while index < children.count {
      let row = calculateRow(
        children: children,
        startIndex: index,
        normalizedWidth: normalizedWidth,
        total: Double(total)
      )
      guard row.count > 0 else { break }
      rows.append((row.height, children[index..<(index + row.count)], row.widths))
      index += row.count
    }

    var result: [TreeMapRect] = []
    let parentLongStart = horizontal ? rect.minX : rect.minY
    let parentShortStart = horizontal ? rect.minY : rect.minX
    let parentLongEnd = horizontal ? rect.maxX : rect.maxY
    let parentShortEnd = horizontal ? rect.maxY : rect.maxX
    var shortStart = parentShortStart

    for (rowIndex, row) in rows.enumerated() {
      guard !Task.isCancelled else { return [] }
      let proposedShortEnd = shortStart + CGFloat(row.height) * shortSide
      let shortEnd =
        rowIndex == rows.count - 1
        ? parentShortEnd : min(max(proposedShortEnd.rounded(), shortStart), parentShortEnd)
      var longStart = parentLongStart

      for (childIndex, child) in row.children.enumerated() {
        let proposedLongEnd = longStart + CGFloat(row.widths[childIndex]) * longSide
        let longEnd =
          childIndex == row.children.count - 1
          ? parentLongEnd : min(max(proposedLongEnd.rounded(), longStart), parentLongEnd)
        let childRect =
          horizontal
          ? CGRect(
            x: longStart, y: shortStart, width: longEnd - longStart, height: shortEnd - shortStart)
          : CGRect(
            x: shortStart, y: longStart, width: shortEnd - shortStart, height: longEnd - longStart)

        if childRect.width >= 1, childRect.height >= 1 {
          result.append(
            contentsOf: layoutNode(
              node: child,
              in: childRect,
              showPackageContents: showPackageContents,
              depth: depth + 1
            ))
        }
        longStart = longEnd
      }
      shortStart = shortEnd
    }

    return result
  }

  private static func calculateRow(
    children: [FileNode],
    startIndex: Int,
    normalizedWidth: Double,
    total: Double
  ) -> (height: Double, widths: [Double], count: Int) {
    var sizeUsed = 0.0
    var rowHeight = 0.0
    var count = 0

    for index in startIndex..<children.count {
      sizeUsed += Double(children[index].size)
      let proposedHeight = sizeUsed / total
      let childWidth = Double(children[index].size) / total * normalizedWidth / proposedHeight

      if count > 0, childWidth / proposedHeight < minimumAspectRatio {
        break
      }
      rowHeight = proposedHeight
      count += 1
    }

    guard count > 0 else { return (0, [], 0) }
    let rowSize = total * rowHeight
    let widths = children[startIndex..<(startIndex + count)].map { Double($0.size) / rowSize }
    return (rowHeight, widths, count)
  }
}
