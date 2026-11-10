//
//  TreemapView.swift
//  DIXApp
//
//  The treemap: lays out and shades with DIXTreemap at the view's backing
//  resolution (Retina), draws the original's yellow selection frame, and
//  reports the cell under the pointer. Layout and shading run on a background
//  queue; while a new image is being made (live resize, zoom) the previous one
//  stays on screen, scaled.
//
//  GPL v3
//

import AppKit
import DIXCore
import DIXTreemap

protocol TreemapViewDelegate: AnyObject {
    /// the pointer moved over a different cell (nil: left the treemap)
    func treemapView(_ view: TreemapView, hovered hit: TreemapHit?, pixelX: Int, pixelY: Int)
    func treemapView(_ view: TreemapView, clicked hit: TreemapHit?, clickCount: Int)
    func treemapView(_ view: TreemapView, menuFor hit: TreemapHit?) -> NSMenu?
    /// a new layout is on screen
    func treemapViewDidRender(_ view: TreemapView)
}

final class TreemapView: NSView {
    weak var delegate: TreemapViewDelegate?

    /// what to draw
    struct Content {
        var model: TreemapModel
        var root: NodeIndex
        var options: TreemapOptions
    }

    private(set) var content: Content?
    /// the layout currently on screen
    private(set) var layout: TreemapLayout?
    private var image: CGImage?
    /// the node shown selected (the frame goes around its cell, or the merged cell it's in)
    var selectedNode: NodeIndex? { didSet { if selectedNode != oldValue { updateSelectionCell() } } }
    private(set) var selectedCell: Int?
    /// kind indexes whose files are highlighted (the others are dimmed); nil = none
    var highlightedKinds: Set<Int>? { didSet { if highlightedKinds != oldValue { updateHighlight() } } }
    private var highlightRects: [CGRect] = []
    private var hoveredCell: Int?

    private let renderQueue = DispatchQueue(label: "dix.treemap.render", qos: .userInitiated)
    private var generation = 0
    private var rendering = false
    private var pendingRender = false
    /// timings of the last layout and shading, in seconds (for the harness)
    private(set) var lastLayoutTime: Double = 0
    private(set) var lastRenderTime: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: content

    func setContent(_ content: Content?) {
        self.content = content
        generation += 1
        if content == nil {
            layout = nil
            image = nil
            needsDisplay = true
            return
        }
        scheduleRender()
    }

    private var pixelSize: (width: Int, height: Int, scale: Double) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let px = convertToBacking(NSRect(origin: .zero, size: bounds.size)).size
        let s = window == nil ? scale : Double(px.width) / max(1, Double(bounds.width))
        let w = window == nil ? Int((bounds.width * scale).rounded()) : Int(px.width.rounded())
        let h = window == nil ? Int((bounds.height * scale).rounded()) : Int(px.height.rounded())
        return (max(0, w), max(0, h), s.isFinite && s > 0 ? s : scale)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed && content != nil { scheduleRender() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if content != nil { scheduleRender() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if content != nil { scheduleRender() }
    }

    /// Lays out and renders right now on this thread (offscreen rendering, tests).
    func renderNow() {
        guard let content else { return }
        let (w, h, scale) = pixelSize
        let result = Self.render(content, width: w, height: h, scale: scale)
        install(result, generation: generation)
    }

    private func scheduleRender() {
        guard content != nil else { return }
        if rendering { pendingRender = true; return }
        guard let content else { return }
        let (w, h, scale) = pixelSize
        guard w > 0, h > 0 else { return }
        rendering = true
        pendingRender = false
        let gen = generation
        renderQueue.async { [weak self] in
            let result = Self.render(content, width: w, height: h, scale: scale)
            DispatchQueue.main.async {
                guard let self else { return }
                self.rendering = false
                self.install(result, generation: gen)
                if self.pendingRender || gen != self.generation || !self.matchesSize(result.layout) {
                    self.scheduleRender()
                }
            }
        }
    }

    private func matchesSize(_ l: TreemapLayout) -> Bool {
        let (w, h, _) = pixelSize
        return l.pixelWidth == w && l.pixelHeight == h
    }

    private struct RenderResult: @unchecked Sendable {
        var layout: TreemapLayout
        var image: CGImage?
        var layoutTime: Double
        var renderTime: Double
    }

    private static func render(_ content: Content, width: Int, height: Int, scale: Double) -> RenderResult {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let layout = content.model.layout(root: content.root, pixelWidth: width, pixelHeight: height,
                                          scale: scale, options: content.options)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let image = layout.render().makeCGImage()
        let t2 = DispatchTime.now().uptimeNanoseconds
        return RenderResult(layout: layout, image: image, layoutTime: Double(t1 - t0) / 1e9,
                            renderTime: Double(t2 - t1) / 1e9)
    }

    private func install(_ result: RenderResult, generation gen: Int) {
        // a result for older content is still better than nothing while resizing,
        // but never show a different snapshot/root than asked for
        guard gen == generation else { return }
        layout = result.layout
        image = result.image
        lastLayoutTime = result.layoutTime
        lastRenderTime = result.renderTime
        hoveredCell = nil
        updateSelectionCell()
        updateHighlight()
        needsDisplay = true
        delegate?.treemapViewDidRender(self)
    }

    // MARK: selection and highlight

    private func updateSelectionCell() {
        if let layout, let node = selectedNode {
            selectedCell = layout.cellIndex(for: node)
        } else {
            selectedCell = nil
        }
        needsDisplay = true
    }

    private func updateHighlight() {
        highlightRects = []
        if let kinds = highlightedKinds, let layout {
            let colors = layout.model.kindColors
            let slots = Set(kinds.map { colors.slot(ofKind: $0) }).subtracting([KindColors.colorSlotCount - 1])
            let s = layout.model.snapshot
            for i in layout.drawnCells {
                let c = layout.cell(i)
                var match = false
                switch c.role {
                case .item: match = kinds.contains(Int(s.kindIndex[c.node])) && !(s.isDirectory(c.node) && !s.flags[c.node].contains(.package))
                case .merged, .mergedPart: match = c.colorSlot.map { slots.contains($0) } ?? false
                default: match = false
                }
                if match { highlightRects.append(pointRect(c.rect, layout)) }
            }
        }
        needsDisplay = true
    }

    private func pointRect(_ r: PixelRect, _ layout: TreemapLayout) -> CGRect {
        // map the layout's pixels onto the current bounds (they differ while resizing)
        let sx = bounds.width / max(1, CGFloat(layout.pixelWidth))
        let sy = bounds.height / max(1, CGFloat(layout.pixelHeight))
        return CGRect(x: CGFloat(r.x) * sx, y: CGFloat(r.y) * sy, width: CGFloat(r.width) * sx, height: CGFloat(r.height) * sy)
    }

    /// the rect (in view coordinates) showing a node, or nil
    func rect(for node: NodeIndex) -> CGRect? {
        guard let layout, let cell = layout.cellIndex(for: node) else { return nil }
        return pointRect(layout.cell(cell).rect, layout)
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        guard let image, let layout else { return }
        ctx.interpolationQuality = layout.pixelWidth == pixelSize.width ? .none : .medium
        func drawImage() {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
        }
        drawImage()
        if highlightedKinds != nil {
            ctx.setFillColor(NSColor(white: 0, alpha: 0.62).cgColor)
            ctx.fill(bounds)
            if !highlightRects.isEmpty {
                ctx.saveGState()
                ctx.clip(to: highlightRects)
                drawImage()
                ctx.restoreGState()
            }
        }
        if let cell = selectedCell, cell < layout.cellCount {
            ctx.setFillColor(NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1).cgColor)
            for r in layout.selectionFrameRects(cell: cell) {
                ctx.fill(pointRect(r, layout))
            }
        }
    }

    // MARK: mouse

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeInActiveApp],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// the layout pixel under a point in view coordinates
    private func layoutPixel(_ p: NSPoint) -> (Int, Int)? {
        guard let layout, bounds.width > 0, bounds.height > 0 else { return nil }
        let x = Int((p.x / bounds.width * CGFloat(layout.pixelWidth)).rounded(.down))
        let y = Int((p.y / bounds.height * CGFloat(layout.pixelHeight)).rounded(.down))
        guard x >= 0, y >= 0, x < layout.pixelWidth, y < layout.pixelHeight else { return nil }
        return (x, y)
    }

    func hit(at point: NSPoint) -> TreemapHit? {
        guard let layout, let (x, y) = layoutPixel(point) else { return nil }
        return layout.hitTest(pixelX: x, y: y)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let layout, let (x, y) = layoutPixel(p) else {
            if hoveredCell != nil { hoveredCell = nil; delegate?.treemapView(self, hovered: nil, pixelX: 0, pixelY: 0) }
            return
        }
        let cell = layout.cellIndex(atPixelX: x, y: y)
        guard cell != hoveredCell else { return }
        hoveredCell = cell
        delegate?.treemapView(self, hovered: cell.map { layout.hit(forCell: $0) }, pixelX: x, pixelY: y)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredCell = nil
        delegate?.treemapView(self, hovered: nil, pixelX: 0, pixelY: 0)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let hit = hit(at: convert(event.locationInWindow, from: nil))
        delegate?.treemapView(self, clicked: hit, clickCount: event.clickCount)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let hit = hit(at: convert(event.locationInWindow, from: nil))
        return delegate?.treemapView(self, menuFor: hit)
    }

    // MARK: offscreen

    /// the treemap as rendered (no frame), for tests and the harness
    var renderedImage: CGImage? { image }
}
