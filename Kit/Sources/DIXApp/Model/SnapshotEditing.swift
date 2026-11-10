//
//  SnapshotEditing.swift
//  DIXApp
//
//  Editing a Snapshot after a scan: removing trashed items and splicing in a
//  rescanned folder, without rescanning everything. The work is DIXCore's
//  `Snapshot.removing(_:)` and `Snapshot.replacingSubtree(at:with:)`; the app
//  calls them through `SnapshotEdits` (one place to adapt if they change).
//  Plus a few lookups the app needs: node by path, ancestry.
//
//  GPL v3
//

import DIXCore
import Foundation

public enum SnapshotEdits {
    /// Removes the nodes (with their subtrees). The root can't be removed.
    public static func removing(_ snapshot: Snapshot, _ nodes: [NodeIndex]) -> (snapshot: Snapshot, indexMap: [UInt32]) {
        snapshot.removing(nodes)
    }

    /// Replaces the subtree at `node` with `subtree` (a scan of the same folder;
    /// its root's name is replaced by the node's own name).
    public static func replacingSubtree(_ snapshot: Snapshot, at node: NodeIndex, with subtree: Snapshot)
        -> (snapshot: Snapshot, indexMap: [UInt32]) {
        snapshot.replacingSubtree(at: node, with: subtree)
    }
}

extension Snapshot {
    /// The node at an absolute path, or nil (walks down by name from the root).
    public func findNode(path: String) -> NodeIndex? {
        let base = rootPath.hasSuffix("/") && rootPath.count > 1 ? String(rootPath.dropLast()) : rootPath
        if path == base || path == rootPath { return Snapshot.root }
        let prefix = base == "/" ? "/" : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var node = Snapshot.root
        for component in path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true) {
            let bytes = Array(component.utf8)
            var found: NodeIndex?
            for child in children(of: node) {
                let start = Int(nameOffset[child]), length = Int(nameLength[child])
                if length == bytes.count && nameBytes[start ..< start + length].elementsEqual(bytes) {
                    found = child
                    break
                }
            }
            guard let next = found else { return nil }
            node = next
        }
        return node
    }

    /// whether `node` is `ancestor` or lies below it
    public func isNode(_ node: NodeIndex, inSubtreeOf ancestor: NodeIndex) -> Bool {
        var n = node
        var steps = 0
        while true {
            if n == ancestor { return true }
            if n == Snapshot.root || steps > nodeCount { return false }
            n = Int(parent[n])
            steps += 1
        }
    }

    /// the path from the root to `node`, both included
    public func ancestry(of node: NodeIndex) -> [NodeIndex] {
        var path: [NodeIndex] = [node]
        var n = node
        while n != Snapshot.root && path.count <= nodeCount {
            n = Int(parent[n])
            path.append(n)
        }
        return path.reversed()
    }
}

