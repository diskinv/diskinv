//
//  DocumentModel.swift
//  DIXApp
//
//  The state of one document window, without any UI: the snapshot, the view
//  options, the zoom stack, the selection and the highlighted kind. The
//  window's controllers (outline, treemap, kinds, selection list) all observe
//  it, which keeps them in sync with each other the way the original's
//  notifications did (GlobalSelectionChanged, ZoomedItemChanged,
//  FSItemsChanged, ViewOptionChanged).
//
//  GPL v3
//

import DIXCore
import DIXTreemap
import Foundation

/// The original's per-document view options (View menu; defaults from Preferences).
public struct ViewOptions: Equatable, Sendable {
    /// "Show Physical File Size": bytes on disk (default) or file length
    public var sizeMode: SizeMode = .allocated
    public var showPackageContents = false
    public var showFreeSpace = false
    public var showOtherSpace = false

    public init(sizeMode: SizeMode = .allocated, showPackageContents: Bool = false,
                showFreeSpace: Bool = false, showOtherSpace: Bool = false) {
        self.sizeMode = sizeMode
        self.showPackageContents = showPackageContents
        self.showFreeSpace = showFreeSpace
        self.showOtherSpace = showOtherSpace
    }

    static let physicalSizeKey = "ShowPhysicalFileSize"
    static let packageContentsKey = "ShowPackageContents"
    static let freeSpaceKey = "ShowFreeSpace"
    static let otherSpaceKey = "ShowOtherSpace"

    /// the defaults new windows start with (the original's preference keys)
    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> ViewOptions {
        defaults.register(defaults: [physicalSizeKey: true])
        return ViewOptions(sizeMode: defaults.bool(forKey: physicalSizeKey) ? .allocated : .logical,
                           showPackageContents: defaults.bool(forKey: packageContentsKey),
                           showFreeSpace: defaults.bool(forKey: freeSpaceKey),
                           showOtherSpace: defaults.bool(forKey: otherSpaceKey))
    }
}

public final class DocumentModel {
    public enum Change: Equatable {
        /// the selected node changed; `origin` is who changed it (to avoid echoes)
        case selection
        case zoom
        /// the snapshot was replaced (trash, refresh)
        case snapshot
        case options
        case highlight
    }

    public private(set) var snapshot: Snapshot
    public private(set) var options: ViewOptions
    /// [root, ..., zoomed folder]
    public private(set) var zoomStack: [NodeIndex] = [Snapshot.root]
    public private(set) var selection: NodeIndex?
    /// who made the last selection change (an outline, a treemap view, ...)
    public private(set) weak var selectionOrigin: AnyObject?
    /// the kind (by name, as the kind statistics group them) whose files are highlighted
    public private(set) var highlightedKind: String?
    /// the index map of the last `replaceSnapshot` (nil when it was matched by path)
    public private(set) var lastIndexMap: [UInt32]?

    private var observers: [(id: Int, block: (Change) -> Void)] = []
    private var nextObserverID = 0
    private var cachedTreemapModel: TreemapModel?
    private var cachedKindStatistics: KindStatistics?

    public init(snapshot: Snapshot, options: ViewOptions = ViewOptions()) {
        self.snapshot = snapshot
        self.options = options
    }

    // MARK: observing

    @discardableResult
    public func observe(_ block: @escaping (Change) -> Void) -> Int {
        nextObserverID += 1
        observers.append((nextObserverID, block))
        return nextObserverID
    }

    public func removeObserver(_ id: Int) {
        observers.removeAll { $0.id == id }
    }

    private func post(_ change: Change) {
        for o in observers { o.block(change) }
    }

    // MARK: derived data

    /// colors, display order and merged-cell data for the current options
    public var treemapModel: TreemapModel {
        if let m = cachedTreemapModel { return m }
        let m = TreemapModel(snapshot: snapshot, sizeMode: options.sizeMode,
                             showPackageContents: options.showPackageContents)
        cachedTreemapModel = m
        return m
    }

    public var hasTreemapModel: Bool { cachedTreemapModel != nil }

    /// install a model computed elsewhere (off the main thread) if it still matches
    public func adoptTreemapModel(_ model: TreemapModel) {
        guard cachedTreemapModel == nil, model.sizeMode == options.sizeMode,
              model.showPackageContents == options.showPackageContents,
              model.snapshot.nodeCount == snapshot.nodeCount, model.snapshot.scanDate == snapshot.scanDate else { return }
        cachedTreemapModel = model
    }

    public var kindStatistics: KindStatistics {
        if let s = cachedKindStatistics { return s }
        let s = KindStatistics(model: treemapModel)
        cachedKindStatistics = s
        return s
    }

    public var zoomedNode: NodeIndex { zoomStack.last ?? Snapshot.root }

    public func size(of node: NodeIndex) -> UInt64 { snapshot.size(of: node, mode: options.sizeMode) }

    /// whether a node is shown as a folder with children (in the outline: expandable).
    /// Packages are, only when package contents are shown.
    public func isContainer(_ node: NodeIndex) -> Bool {
        let f = snapshot.flags[node]
        guard f.contains(.directory), snapshot.childCount[node] > 0 else { return false }
        return options.showPackageContents || !f.contains(.package) || node == zoomedNode
    }

    /// a node's children in display order (largest first in the current size mode)
    public func orderedChildren(of node: NodeIndex) -> [NodeIndex] {
        options.sizeMode == .allocated ? Array(snapshot.children(of: node)) : treemapModel.orderedChildren(of: node)
    }

    /// the package a node is hidden in (when package contents are not shown), or nil
    public func enclosingHiddenPackage(of node: NodeIndex) -> NodeIndex? {
        guard !options.showPackageContents else { return nil }
        var found: NodeIndex?
        var n = node
        while n != zoomedNode && n != Snapshot.root {
            n = Int(snapshot.parent[n])
            if n != zoomedNode && snapshot.flags[n].contains(.package) { found = n }
        }
        return found
    }

    // MARK: selection

    public func select(_ node: NodeIndex?, origin: AnyObject? = nil) {
        var node = node
        if let n = node, n < 0 || n >= snapshot.nodeCount || !snapshot.isNode(n, inSubtreeOf: zoomedNode) { node = nil }
        selectionOrigin = origin
        guard node != selection else { return }
        selection = node
        if let h = highlightedKind, let n = node, !snapshot.isDirectory(n) || snapshot.flags[n].contains(.package) {
            if snapshot.kind(of: n).name != h { highlightedKind = nil; post(.highlight) }
        }
        post(.selection)
    }

    public func highlightKind(_ name: String?) {
        guard name != highlightedKind else { return }
        highlightedKind = name
        post(.highlight)
    }

    /// "Select Parent Folder": not above the zoomed folder's children
    public var canSelectParent: Bool {
        guard let s = selection else { return false }
        return s != zoomedNode && Int(snapshot.parent[s]) != zoomedNode
    }

    public func selectParent() {
        guard canSelectParent, let s = selection else { return }
        select(Int(snapshot.parent[s]))
    }

    // MARK: zooming

    public var canZoomIn: Bool {
        guard let s = selection, s != zoomedNode else { return false }
        let f = snapshot.flags[s]
        return f.contains(.directory) && snapshot.childCount[s] > 0
    }

    public var canZoomOut: Bool { zoomStack.count > 1 }

    /// zooms into the selected folder
    public func zoomIn() {
        guard canZoomIn, let s = selection else { return }
        zoom(into: s)
    }

    /// zooms into a folder below the zoomed one
    public func zoom(into node: NodeIndex) {
        guard node != zoomedNode, snapshot.isDirectory(node), snapshot.childCount[node] > 0,
              snapshot.isNode(node, inSubtreeOf: zoomedNode) else { return }
        zoomStack.append(node)
        var clear = false
        if let s = selection, s == node || !snapshot.isNode(s, inSubtreeOf: node) { selection = nil; clear = true }
        post(.zoom)
        if clear { post(.selection) }
    }

    /// one step out; the folder zoomed out of becomes the selection (as the original did)
    public func zoomOut() {
        guard canZoomOut else { return }
        let previous = zoomStack.removeLast()
        post(.zoom)
        select(previous)
    }

    /// out to an entry of the zoom stack ("Zoom Out To" menu)
    public func zoomOut(to node: NodeIndex) {
        guard let i = zoomStack.lastIndex(of: node), i < zoomStack.count - 1 else { return }
        let previous = zoomedNode
        zoomStack.removeSubrange((i + 1)...)
        post(.zoom)
        select(previous)
    }

    // MARK: options

    public func setOptions(_ new: ViewOptions) {
        guard new != options else { return }
        let rebuild = new.sizeMode != options.sizeMode || new.showPackageContents != options.showPackageContents
        options = new
        if rebuild {
            cachedTreemapModel = nil
            cachedKindStatistics = nil
        }
        // a selection hidden inside a package now selects the package
        if let s = selection, let package = enclosingHiddenPackage(of: s) {
            selection = package
            post(.selection)
        }
        post(.options)
    }

    // MARK: replacing the snapshot

    /// Installs an edited snapshot (after a move to the trash or a refresh).
    /// Zoom and selection follow `indexMap` (old -> new, UInt32.max = gone); a
    /// zoomed folder that is gone is looked up again by path (a refreshed
    /// folder's contents are new nodes), else the zoom stops there.
    public func replaceSnapshot(_ new: Snapshot, indexMap: [UInt32]?) {
        let old = snapshot
        func map(_ node: NodeIndex) -> NodeIndex? {
            if let indexMap {
                if node < indexMap.count, indexMap[node] != .max { return Int(indexMap[node]) }
                return new.findNode(path: old.path(of: node))
            }
            return new.findNode(path: old.path(of: node))
        }
        var stack: [NodeIndex] = [Snapshot.root]
        for node in zoomStack.dropFirst() {
            guard let m = map(node), new.isDirectory(m), new.childCount[m] > 0, m != stack.last else { break }
            stack.append(m)
        }
        let newSelection = selection.flatMap(map)
        let zoomChanged = stack.count != zoomStack.count
        snapshot = new
        zoomStack = stack
        lastIndexMap = indexMap
        cachedTreemapModel = nil
        cachedKindStatistics = nil
        selection = newSelection.flatMap { new.isNode($0, inSubtreeOf: zoomedNode) ? $0 : nil }
        selectionOrigin = nil
        post(.snapshot)
        if zoomChanged { post(.zoom) }
        post(.selection)
    }
}
