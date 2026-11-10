//
//  OffscreenShots.swift
//  DIXApp
//
//  For the dix-app-shots harness: builds the real windows and panels without
//  ever showing them, renders them offscreen to PNG (cacheDisplay), and times
//  the document window on a snapshot. Nothing here touches files except the
//  PNGs it writes.
//
//  GPL v3
//

import AppKit
import DIXCore
import DIXTreemap

public final class OffscreenShots {
    let outDir: URL
    let dark: Bool

    public init(outDir: URL, dark: Bool) {
        self.outDir = outDir
        self.dark = dark
    }

    private func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
    private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func spin(_ seconds: Double = 0.05) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// renders a window, including its title bar and toolbar, to PNG
    @discardableResult
    public func capture(_ window: NSWindow, _ name: String) -> URL? {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let content = window.contentView else { return nil }
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        return capture(view: view, name)
    }

    @discardableResult
    func capture(view: NSView, _ name: String) -> URL? {
        let rect = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = outDir.appendingPathComponent(name + (dark ? "-dark" : "") + ".png")
        try? data.write(to: url)
        print("wrote \(url.path)")
        return url
    }

    public func run(snapshotURL: URL, size: NSSize, only: Set<String>?) {
        func wants(_ s: String) -> Bool { only == nil || only!.contains(s) }
        let tLoad = now()
        guard let snapshot = try? Snapshot(contentsOf: snapshotURL) else {
            print("can't load \(snapshotURL.path)")
            return
        }
        let loadMs = ms(tLoad)
        let sum = snapshot.summary
        print("summary: \(sum.files) files, \(sum.directories) folders, \(sum.cloudFiles) cloud files, \(sum.cloudFolders) cloud folders, \(sum.unreadableFolders) unreadable")

        if wants("drives") { shootDrives() }
        if wants("progress") { shootProgress() }

        let tModel = now()
        let doc = ScanDocument(snapshot: snapshot, options: ViewOptions())
        _ = doc.model.treemapModel
        let modelMs = ms(tModel)
        let tStats = now()
        _ = doc.model.kindStatistics
        let statsMs = ms(tStats)
        let tWindow = now()
        doc.makeWindowControllers()
        guard let wc = doc.windowController, let window = wc.window else {
            print("no window controller (\(doc.windowControllers))")
            return
        }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(size)
        window.contentView?.layoutSubtreeIfNeeded()
        spin()
        let windowMs = ms(tWindow)
        let tRender = now()
        wc.treemapView.renderNow()
        let renderMs = ms(tRender)
        print(String(format: "nodes %d · load %.0f ms · treemap model %.0f ms · kind stats %.0f ms · window %.0f ms · first layout+render %.0f ms (layout %.0f, shade %.0f) at %dx%d px",
                     snapshot.nodeCount, loadMs, modelMs, statsMs, windowMs, renderMs,
                     wc.treemapView.lastLayoutTime * 1000, wc.treemapView.lastRenderTime * 1000,
                     wc.treemapView.layout?.pixelWidth ?? 0, wc.treemapView.layout?.pixelHeight ?? 0))
        print(String(format: "open total (load + model + stats + window + render): %.0f ms", loadMs + modelMs + statsMs + windowMs + renderMs))

        let model = doc.model!
        let s = model.snapshot
        // a selection to show: the largest file, a few levels down the largest folders
        var node = Snapshot.root
        var depth = 0
        while depth < 4, model.isContainer(node), let first = model.orderedChildren(of: node).first(where: { s.isDirectory($0) }) {
            node = first
            depth += 1
        }
        let file = model.orderedChildren(of: node).first(where: { !s.isDirectory($0) }) ?? node
        model.select(file)
        hover(wc, at: CGPoint(x: wc.treemapView.bounds.width * 0.3, y: wc.treemapView.bounds.height * 0.6))
        spin()
        if wants("main") { capture(window, "main-window") }
        if wants("kinds") { capture(view: wc.kinds.scrollView.superview ?? wc.kinds.scrollView, "kinds-pane") }

        if wants("merged") {
            // hover over a merged area, if the layout has one
            if let layout = wc.treemapView.layout, let g = layout.mergedGroups.max(by: { $0.size < $1.size }) {
                let r = layout.cell(g.cell).rect
                let p = CGPoint(x: (Double(r.x) + Double(r.width) / 2) / layout.scale, y: (Double(r.y) + Double(r.height) / 2) / layout.scale)
                hover(wc, at: p)
                print("merged hover: \(wc.nameField.stringValue) | \(wc.sizeField.stringValue)")
                capture(window, "main-window-merged-hover")
            }
        }

        if wants("info") {
            InfoPanelController.shared.update((model, file))
            capture(InfoPanelController.shared.panel, "info-panel")
        }

        if wants("highlight") {
            if let kind = model.kindStatistics.entries.dropFirst().first {
                model.highlightKind(kind.name)
                spin()
                capture(window, "main-window-kind-highlight")
                model.highlightKind(nil)
            }
        }

        if wants("selection") {
            wc.setSelectionListVisible(true, animated: false)
            if let kind = model.kindStatistics.entries.first { wc.selectionList.showKind(kind.name) }
            wc.selectionList.recomputeNow()
            window.contentView?.layoutSubtreeIfNeeded()
            spin(0.2)
            capture(window, "main-window-selection-list")
            wc.setSelectionListVisible(false, animated: false)
            window.contentView?.layoutSubtreeIfNeeded()
        }

        if wants("notice") {
            wc.showUnreadableNotice(12)
            window.contentView?.layoutSubtreeIfNeeded()
            spin()
            capture(window, "main-window-notice")
            wc.hideNotice()
        }

        if wants("perf") { perf(wc, model) }

        if wants("zoomed") {
            if let folder = model.orderedChildren(of: Snapshot.root).first(where: { model.isContainer($0) }) {
                let t = now()
                model.zoom(into: folder)
                wc.treemapView.renderNow()
                print(String(format: "zoom into %@: %.0f ms (layout %.0f, shade %.0f)", s.name(of: folder), ms(t),
                             wc.treemapView.lastLayoutTime * 1000, wc.treemapView.lastRenderTime * 1000))
                spin()
                capture(window, "main-window-zoomed")
                let t2 = now()
                model.zoomOut()
                wc.treemapView.renderNow()
                print(String(format: "zoom out: %.0f ms", ms(t2)))
            }
        }

        if wants("logical") {
            var o = model.options
            o.sizeMode = .logical
            let t = now()
            model.setOptions(o)
            wc.treemapView.renderNow()
            print(String(format: "switch to file sizes (logical): %.0f ms", ms(t)))
            spin()
            capture(window, "main-window-logical")
        }
    }

    func hover(_ wc: DocumentWindowController, at p: CGPoint) {
        guard let layout = wc.treemapView.layout else { return }
        let x = Int(p.x * layout.scale), y = Int(p.y * layout.scale)
        wc.treemapView(wc.treemapView, hovered: layout.hitTest(pixelX: x, y: y), pixelX: x, pixelY: y)
    }

    private func perf(_ wc: DocumentWindowController, _ model: DocumentModel) {
        let s = model.snapshot
        // the folder with the most children: expanding it is the outline's worst case
        var widest = Snapshot.root
        for n in 0 ..< s.nodeCount where s.childCount[n] > s.childCount[widest] && model.isContainer(n) { widest = n }
        model.zoomOut(to: Snapshot.root)
        let t = now()
        model.select(model.orderedChildren(of: widest).last ?? widest)   // expands every ancestor, scrolls to it
        wc.outline.outlineView.layoutSubtreeIfNeeded()
        print(String(format: "reveal the last of %@ children of %@: %.0f ms (outline rows: %d)",
                     Format.count(Int(s.childCount[widest])), s.name(of: widest), ms(t), wc.outline.outlineView.numberOfRows))
        // scrolling: page through the outline, drawing each page
        let ov = wc.outline.outlineView
        let clip = wc.outline.scrollView.contentView
        let rowsPerPage = max(1, Int(clip.bounds.height / (ov.rowHeight + ov.intercellSpacing.height)))
        let pages = min(200, ov.numberOfRows / rowsPerPage)
        guard pages > 1, let rep = wc.outline.scrollView.bitmapImageRepForCachingDisplay(in: wc.outline.scrollView.bounds) else { return }
        let t2 = now()
        for p in 0 ..< pages {
            let y = CGFloat(p * rowsPerPage) * (ov.rowHeight + ov.intercellSpacing.height)
            clip.scroll(to: NSPoint(x: 0, y: y))
            wc.outline.scrollView.reflectScrolledClipView(clip)
            wc.outline.scrollView.cacheDisplay(in: wc.outline.scrollView.bounds, to: rep)
        }
        let total = ms(t2)
        print(String(format: "outline scrolling: %d pages of %d rows, %.1f ms per page (drawn)", pages, rowsPerPage, total / Double(pages)))
        capture(view: wc.outline.scrollView, "outline-after-scroll")
        // relayout on resize
        let t3 = now()
        wc.treemapView.renderNow()
        print(String(format: "treemap relayout+render at the same size: %.0f ms", ms(t3)))
    }

    private func shootDrives() {
        let drives = DrivesPanelController.shared
        drives.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        drives.window.contentView?.layoutSubtreeIfNeeded()
        drives.tableView.layoutSubtreeIfNeeded()
        spin()
        capture(drives.window, "drives-panel")
    }

    private func shootProgress() {
        let p = ProgressPanel()
        var rate = ScanEstimate.Rate()
        _ = ScanEstimate.status(rootPath: "/Users/mla/b", displayName: "b", items: 0, bytes: 0, currentPath: "/Users/mla/b",
                                expectedItems: 438_000, elapsed: 0, rate: &rate)
        let status = ScanEstimate.status(rootPath: "/Users/mla/b", displayName: "b", items: 184_203, bytes: 6_100_000_000,
                                         currentPath: "/Users/mla/b/a/cowboy/server/node_modules/typescript/lib",
                                         expectedItems: 438_000, elapsed: 7.4, rate: &rate)
        p.update(status)
        capture(p.panel, "progress-panel")
        let unknown = ScanEstimate.status(rootPath: "/Users/mla/_greek", displayName: "_greek", items: 1_204_311, bytes: 41_200_000_000,
                                          currentPath: "/Users/mla/_greek/protocol/lib/forge-std/src",
                                          expectedItems: nil, elapsed: 12, rate: &rate)
        let p2 = ProgressPanel()
        p2.update(unknown)
        capture(p2.panel, "progress-panel-unknown-total")
    }
}

extension OffscreenShots {
    /// A made-up iCloud Drive folder with placeholders ("dataless" files), to
    /// see the cloud badge, the washed-out cells (file sizes) and the hover text.
    public func runCloudFixture(size: NSSize) {
        var docs: [FixtureItem] = []
        for i in 0 ..< 12 {
            docs.append(.file("Scan \(i + 1).pdf", size: UInt64(400_000 + i * 90_000), kind: "PDF document"))
        }
        let s = SnapshotBuilder.build(.folder("com~apple~CloudDocs", [
            .folder("Photos export", [
                .file("IMG_0001.HEIC", size: 0, logical: 3_100_000_000, kind: "HEIF image", flags: .cloudPlaceholder),
                .file("IMG_0002.HEIC", size: 2_400_000_000, kind: "HEIF image"),
                .file("IMG_0003.HEIC", size: 0, logical: 1_900_000_000, kind: "HEIF image", flags: .cloudPlaceholder),
            ]),
            .folder("Documents", docs),
            .file("Holiday.mov", size: 0, logical: 4_200_000_000, kind: "QuickTime movie", flags: .cloudPlaceholder),
            .file("Notes.txt", size: 40_000, kind: "Plain Text"),
            .folder("Archive", [], flags: .cloudPlaceholder),
        ]), rootPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs")
        for mode in [SizeMode.allocated, .logical] {
            let doc = ScanDocument(snapshot: s, options: ViewOptions(sizeMode: mode))
            doc.makeWindowControllers()
            guard let wc = doc.windowController, let window = wc.window else { return }
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            spin()
            wc.treemapView.renderNow()
            if let movie = s.findNode(path: s.rootPath + "/Holiday.mov"), let photos = s.findNode(path: s.rootPath + "/Photos export") {
                wc.model.select(photos)
                wc.outline.revealSelection()
                wc.outline.outlineView.expandItem(wc.outline.outlineView.item(atRow: wc.outline.outlineView.selectedRow))
                wc.model.select(movie)
                if let r = wc.treemapView.rect(for: movie) { hover(wc, at: CGPoint(x: r.midX, y: r.midY)) }
            }
            spin()
            capture(window, mode == .allocated ? "cloud-fixture-disk" : "cloud-fixture-file-sizes")
        }
    }
}
