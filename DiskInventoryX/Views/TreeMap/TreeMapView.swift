import AppKit
import SwiftUI

struct TreeMapView: View {
  @EnvironmentObject private var appState: AppState
  @AppStorage("cushionShading") private var cushionShading = true
  @AppStorage("showLabels") private var showLabels = false
  @AppStorage("minimumRectangleSize") private var minimumRectangleSize = 2.0
  @State private var hoveredNode: FileNode?
  @State private var rectangles: [TreeMapRect] = []
  @State private var layoutSize: CGSize = .zero

  let root: FileNode

  var body: some View {
    GeometryReader { geometry in
      let key = LayoutKey(
        revision: appState.treeRevision,
        width: Int(geometry.size.width.rounded()),
        height: Int(geometry.size.height.rounded()),
        showsPackages: appState.showPackageContents,
        minimumSize: Int(minimumRectangleSize)
      )

      Canvas { context, size in
        guard size.width > 0, size.height > 0 else { return }
        drawBackground(size: size, in: &context)
        var scaledContext = context
        let sourceSize = layoutSize.width > 0 && layoutSize.height > 0 ? layoutSize : size
        scaledContext.scaleBy(
          x: size.width / sourceSize.width,
          y: size.height / sourceSize.height
        )
        for rectangle in rectangles {
          draw(rectangle, in: &scaledContext)
        }
        drawSelection(in: &scaledContext)
        drawHover(in: &scaledContext)
      }
      .background(Color.black)
      .contentShape(Rectangle())
      .gesture(tapGesture(in: geometry.size))
      .onContinuousHover { phase in
        switch phase {
        case .active(let point): hoveredNode = node(at: point, in: geometry.size)
        case .ended: hoveredNode = nil
        }
      }
      .task(id: key) {
        do {
          try await Task.sleep(for: .milliseconds(180))
        } catch {
          return
        }
        let root = root
        let size = geometry.size
        let showPackageContents = appState.showPackageContents
        let minimumSize = CGFloat(minimumRectangleSize)
        let layoutTask = Task.detached(priority: .userInitiated) {
          TreeMapLayout.layout(
            node: root,
            in: CGRect(origin: .zero, size: size),
            showPackageContents: showPackageContents,
            minimumSize: minimumSize
          )
        }
        let newRectangles = await withTaskCancellationHandler {
          await layoutTask.value
        } onCancel: {
          layoutTask.cancel()
        }
        guard !Task.isCancelled else { return }
        rectangles = newRectangles
        layoutSize = size
      }
    }
    .accessibilityLabel("Disk usage treemap")
  }

  private func tapGesture(in size: CGSize) -> some Gesture {
    SpatialTapGesture(count: 2)
      .exclusively(before: SpatialTapGesture(count: 1))
      .onEnded { value in
        switch value {
        case .first(let doubleTap):
          guard let node = node(at: doubleTap.location, in: size) else { return }
          appState.selectedNode = node
          if node.isDirectory {
            appState.zoomIn()
          } else {
            let parentPath = (node.path as NSString).deletingLastPathComponent
            if let parent = appState.rootNode?.node(withID: parentPath) {
              appState.selectedNode = parent
              appState.zoomIn()
            }
          }
        case .second(let singleTap):
          appState.selectedNode = node(at: singleTap.location, in: size)
        }
      }
  }

  private func drawBackground(size: CGSize, in context: inout GraphicsContext) {
    let rect = CGRect(origin: .zero, size: size)
    let colors = cushionColors(for: appState.color(for: root.kindID), depth: 0)
    context.fill(
      Path(rect),
      with: .radialGradient(
        Gradient(colors: [colors.highlight, colors.base, colors.edge]),
        center: CGPoint(x: rect.midX, y: rect.midY),
        startRadius: 0,
        endRadius: max(rect.width, rect.height) * 0.72
      )
    )
  }

  private func draw(_ treeRect: TreeMapRect, in context: inout GraphicsContext) {
    let rect = treeRect.rect.insetBy(dx: 0.35, dy: 0.35)
    guard rect.width > 0, rect.height > 0 else { return }
    let path = Path(rect)
    let base = appState.color(for: treeRect.node.kindID)

    if cushionShading, min(rect.width, rect.height) >= 6 {
      let colors = cushionColors(for: base, depth: treeRect.depth)
      context.fill(
        path,
        with: .radialGradient(
          Gradient(stops: [
            .init(color: colors.highlight, location: 0),
            .init(color: colors.base, location: 0.34),
            .init(color: colors.edge, location: 1),
          ]),
          center: CGPoint(x: rect.midX - rect.width * 0.08, y: rect.midY - rect.height * 0.08),
          startRadius: 0,
          endRadius: max(rect.width, rect.height) * 0.72
        )
      )
    } else {
      context.fill(path, with: .color(base))
    }

    context.stroke(path, with: .color(.black.opacity(0.45)), lineWidth: 0.6)

    if showLabels, !treeRect.isAggregate, rect.width > 52, rect.height > 18 {
      var labelContext = context
      labelContext.clip(to: path)
      labelContext.draw(
        Text(treeRect.node.name)
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(.white),
        at: CGPoint(x: rect.minX + 5, y: rect.minY + 4),
        anchor: .topLeading
      )
    }
  }

  private func drawSelection(in context: inout GraphicsContext) {
    guard let selected = appState.selectedNode else { return }
    let matching = rectangles.filter {
      $0.node.id == selected.id || $0.node.isDescendant(of: selected)
    }
    guard let first = matching.first else { return }
    let bounds = matching.dropFirst().reduce(first.rect) { $0.union($1.rect) }
    context.stroke(
      Path(bounds.insetBy(dx: 1.5, dy: 1.5)),
      with: .color(.white),
      lineWidth: 3
    )
  }

  private func drawHover(in context: inout GraphicsContext) {
    guard let hoveredNode,
      let rectangle = rectangles.first(where: { $0.node.id == hoveredNode.id })
    else { return }
    context.stroke(
      Path(rectangle.rect.insetBy(dx: 1, dy: 1)),
      with: .color(.white.opacity(0.75)),
      lineWidth: 1.5
    )
  }

  private func node(at point: CGPoint, in size: CGSize) -> FileNode? {
    guard size.width > 0, size.height > 0, layoutSize.width > 0, layoutSize.height > 0 else {
      return nil
    }
    let layoutPoint = CGPoint(
      x: point.x * layoutSize.width / size.width,
      y: point.y * layoutSize.height / size.height
    )
    return rectangles.last(where: { $0.rect.contains(layoutPoint) })?.node
  }

  private func cushionColors(for color: Color, depth: Int) -> (
    highlight: Color, base: Color, edge: Color
  ) {
    guard let source = NSColor(color).usingColorSpace(.sRGB) else {
      return (.white, color, .black)
    }
    let depthShade = min(CGFloat(depth) * 0.025, 0.22)
    let highlight = source.blended(withFraction: 0.72, of: .white) ?? source
    let middle = source.blended(withFraction: depthShade, of: .black) ?? source
    let edge = source.blended(withFraction: min(0.58 + depthShade, 0.8), of: .black) ?? source
    return (Color(nsColor: highlight), Color(nsColor: middle), Color(nsColor: edge))
  }
}

private struct LayoutKey: Hashable {
  let revision: UUID
  let width: Int
  let height: Int
  let showsPackages: Bool
  let minimumSize: Int
}
