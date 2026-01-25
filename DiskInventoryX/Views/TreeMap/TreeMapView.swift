//
//  TreeMapView.swift
//  DiskInventoryX
//
//  Treemap visualization using Canvas for efficient rendering
//  Cushion shading ported from original TMVCushionRenderer
//

import SwiftUI

struct TreeMapView: View {
    let root: FileNode
    @Binding var selectedNode: FileNode?
    let colorProvider: (String) -> Color

    @State private var hoveredNode: FileNode?
    @State private var layoutCache: [ObjectIdentifier: TreeMapRect] = [:]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in
                    let rects = TreeMapLayout.layout(
                        node: root,
                        rect: CGRect(origin: .zero, size: size),
                        colorProvider: colorProvider
                    )

                    // Store layout for hit testing
                    DispatchQueue.main.async {
                        self.layoutCache = Dictionary(uniqueKeysWithValues: rects.map { (ObjectIdentifier($0.node), $0) })
                    }

                    // Draw all rectangles with cushion shading
                    for rect in rects {
                        drawCushion(rect, context: context)
                    }

                    // Draw selection/hover highlights on top
                    for rect in rects {
                        drawHighlight(rect, context: context)
                    }
                }

                // Invisible overlay for gestures
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                selectedNode = nodeAt(point: value.location)
                            }
                    )
                    .gesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { value in
                                if let node = nodeAt(point: value.location), node.isDirectory {
                                    selectedNode = node
                                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                                }
                            }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredNode = nodeAt(point: location)
                        case .ended:
                            hoveredNode = nil
                        }
                    }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            if let hovered = hoveredNode ?? selectedNode {
                InfoBar(node: hovered)
            }
        }
    }

    // MARK: - Cushion Rendering

    private func drawCushion(_ treeRect: TreeMapRect, context: GraphicsContext) {
        let rect = treeRect.rect
        guard rect.width >= 1, rect.height >= 1 else { return }

        let baseColor = treeRect.color

        // Create cushion shading using radial gradient
        // Light source is at top-left (-1, -1, 10)
        let cushionPath = Path(CGRect(
            x: rect.minX + 0.5,
            y: rect.minY + 0.5,
            width: rect.width - 1,
            height: rect.height - 1
        ))

        // Cushion effect: brighter at top-left, darker at bottom-right
        // Scale brightness based on depth
        let depthFactor = pow(0.9, Double(treeRect.depth))
        let brightColor = adjustBrightness(baseColor, factor: 1.1 * depthFactor)
        let darkColor = adjustBrightness(baseColor, factor: 0.6 * depthFactor)

        let gradient = Gradient(colors: [brightColor, darkColor])

        context.fill(
            cushionPath,
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
            )
        )

        // Subtle border
        context.stroke(
            cushionPath,
            with: .color(Color.black.opacity(0.15)),
            lineWidth: 0.5
        )

        // Label if rect is large enough
        if rect.width > 60 && rect.height > 24 {
            drawLabel(treeRect.node.name, in: rect, context: context)
        }
    }

    private func drawHighlight(_ treeRect: TreeMapRect, context: GraphicsContext) {
        let rect = treeRect.rect
        let isSelected = treeRect.node === selectedNode
        let isHovered = treeRect.node === hoveredNode

        guard isSelected || isHovered else { return }

        let highlightPath = Path(CGRect(
            x: rect.minX + 0.5,
            y: rect.minY + 0.5,
            width: rect.width - 1,
            height: rect.height - 1
        ))

        if isSelected {
            context.stroke(highlightPath, with: .color(.yellow), lineWidth: 2.5)
        } else if isHovered {
            context.stroke(highlightPath, with: .color(.white.opacity(0.6)), lineWidth: 1.5)
        }
    }

    private func drawLabel(_ text: String, in rect: CGRect, context: GraphicsContext) {
        let fontSize = min(11, rect.height - 6)
        guard fontSize >= 8 else { return }

        let resolvedText = Text(text)
            .font(.system(size: fontSize))
            .foregroundColor(.white.opacity(0.85))

        // Draw with shadow for readability
        context.draw(
            resolvedText,
            at: CGPoint(x: rect.midX, y: rect.midY),
            anchor: .center
        )
    }

    private func adjustBrightness(_ color: Color, factor: Double) -> Color {
        // Convert to NSColor to manipulate components
        let nsColor = NSColor(color)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let newBrightness = min(1.0, max(0.0, brightness * factor))
        return Color(hue: Double(hue),
                     saturation: Double(saturation),
                     brightness: Double(newBrightness),
                     opacity: Double(alpha))
    }

    // MARK: - Hit Testing

    private func nodeAt(point: CGPoint) -> FileNode? {
        // Find the smallest (deepest) rect containing the point
        var bestMatch: TreeMapRect?

        for (_, rect) in layoutCache {
            if rect.rect.contains(point) {
                if bestMatch == nil || rect.depth > bestMatch!.depth {
                    bestMatch = rect
                }
            }
        }

        return bestMatch?.node
    }
}

// MARK: - Info Bar

struct InfoBar: View {
    let node: FileNode

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: node.icon)
                .resizable()
                .frame(width: 16, height: 16)

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(node.kindName)
                .foregroundStyle(.secondary)

            Text(FileSizeFormatter.string(from: node.size))
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let zoomIn = Notification.Name("zoomIn")
}

#Preview {
    let root = FileNode(url: URL(fileURLWithPath: "/"), name: "Root", isDirectory: true, size: 1000)
    let child1 = FileNode(url: URL(fileURLWithPath: "/a"), name: "Large Folder", isDirectory: true, size: 600)
    let child2 = FileNode(url: URL(fileURLWithPath: "/b"), name: "Medium.app", isPackage: true, size: 300)
    let child3 = FileNode(url: URL(fileURLWithPath: "/c"), name: "Small.txt", size: 100)
    root.children = [child1, child2, child3]

    return TreeMapView(
        root: root,
        selectedNode: .constant(nil),
        colorProvider: { _ in .blue }
    )
    .frame(width: 600, height: 400)
}
