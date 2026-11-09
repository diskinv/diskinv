//
//  Snapshot.swift
//  DIXCore
//
//  The result of one scan: an immutable, flat tree. This is the contract
//  between the scanner (DIXScan, which produces it), the .dixsnap file format
//  (which stores it), and the treemap/app (which only read it).
//
//  Layout: nodes are indexes into parallel arrays; node 0 is the root.
//  A node's children are CONTIGUOUS: indexes firstChild ..< firstChild +
//  childCount, sorted by allocatedSize descending (ties: name ascending,
//  byte-wise). Every directory's sizes are the sums over its subtree.
//
//  GPL v3
//

import Foundation

public typealias NodeIndex = Int

/// Per-node flags.
public struct NodeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// a directory (including packages and mount points)
    public static let directory         = NodeFlags(rawValue: 1 << 0)
    /// a package/bundle (e.g. .app); also `directory`
    public static let package           = NodeFlags(rawValue: 1 << 1)
    /// a symbolic link (never followed; counted as a small file)
    public static let symlink           = NodeFlags(rawValue: 1 << 2)
    /// cloud placeholder ("dataless") from iCloud Drive, Dropbox, OneDrive,
    /// Google Drive, ...: its data is not on this disk. allocatedSize is what
    /// it really occupies (about 0); logicalSize is the full cloud size.
    /// A dataless DIRECTORY is not descended (that would download it).
    public static let cloudPlaceholder  = NodeFlags(rawValue: 1 << 3)
    /// a further hard link to a file already counted elsewhere in the
    /// snapshot: its allocatedSize is 0 so the disk space is counted once
    /// (logicalSize keeps the file's length)
    public static let hardLinkDuplicate = NodeFlags(rawValue: 1 << 4)
    /// a directory on which another volume is mounted; not descended
    public static let mountPoint        = NodeFlags(rawValue: 1 << 5)
    /// a directory that could not be read (permissions, privacy protection);
    /// it appears with no children. (Rarely, a listing fails part-way: then
    /// the entries read before the error are kept, and the flag still says
    /// the folder is incomplete.)
    public static let unreadable        = NodeFlags(rawValue: 1 << 6)
}

/// A file kind ("JPEG image", "Swift Source Code"). Kinds are resolved once per
/// distinct type, never once per file.
public struct FileKind: Sendable, Hashable, Codable {
    /// UTI ("public.jpeg"); empty when unknown
    public var identifier: String
    /// localized display name ("JPEG image")
    public var name: String

    public init(identifier: String, name: String) {
        self.identifier = identifier
        self.name = name
    }
}

/// Information about the volume the scanned folder lives on, captured at scan
/// time (for the treemap's optional free-space / other-space areas).
public struct VolumeInfo: Sendable, Hashable, Codable {
    public var name: String
    public var mountPath: String
    public var totalCapacity: UInt64
    public var availableCapacity: UInt64

    public init(name: String, mountPath: String, totalCapacity: UInt64, availableCapacity: UInt64) {
        self.name = name
        self.mountPath = mountPath
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
    }
}

public struct Snapshot: Sendable {
    // MARK: scan metadata

    /// absolute path of the scanned folder (node 0)
    public var rootPath: String
    public var scanDate: Date
    public var volume: VolumeInfo?

    // MARK: node arrays (all have `nodeCount` elements)

    /// parent index; the root's parent is 0 (itself)
    public var parent: [UInt32]
    public var firstChild: [UInt32]
    public var childCount: [UInt32]
    /// bytes on disk (allocated blocks); directories: subtree sum
    public var allocatedSize: [UInt64]
    /// file length in bytes; directories: subtree sum
    public var logicalSize: [UInt64]
    /// name = UTF-8 bytes nameBytes[nameOffset ..< nameOffset + nameLength]
    public var nameOffset: [UInt32]
    public var nameLength: [UInt16]
    /// index into `kinds`; directories that are not packages use kindIndex 0
    /// with kinds[0] = the folder kind
    public var kindIndex: [UInt16]
    public var flags: [NodeFlags]

    // MARK: shared tables

    public var nameBytes: [UInt8]
    public var kinds: [FileKind]

    public init(rootPath: String, scanDate: Date, volume: VolumeInfo?,
                parent: [UInt32], firstChild: [UInt32], childCount: [UInt32],
                allocatedSize: [UInt64], logicalSize: [UInt64],
                nameOffset: [UInt32], nameLength: [UInt16],
                kindIndex: [UInt16], flags: [NodeFlags],
                nameBytes: [UInt8], kinds: [FileKind]) {
        self.rootPath = rootPath
        self.scanDate = scanDate
        self.volume = volume
        self.parent = parent
        self.firstChild = firstChild
        self.childCount = childCount
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.nameOffset = nameOffset
        self.nameLength = nameLength
        self.kindIndex = kindIndex
        self.flags = flags
        self.nameBytes = nameBytes
        self.kinds = kinds
    }

    // MARK: accessors

    public var nodeCount: Int { parent.count }
    public static let root: NodeIndex = 0

    public func children(of node: NodeIndex) -> Range<NodeIndex> {
        let first = Int(firstChild[node])
        return first ..< first + Int(childCount[node])
    }

    public func isDirectory(_ node: NodeIndex) -> Bool {
        flags[node].contains(.directory)
    }

    public func name(of node: NodeIndex) -> String {
        let start = Int(nameOffset[node])
        let end = start + Int(nameLength[node])
        return String(decoding: nameBytes[start ..< end], as: UTF8.self)
    }

    public func kind(of node: NodeIndex) -> FileKind {
        kinds[Int(kindIndex[node])]
    }

    /// absolute path of a node
    public func path(of node: NodeIndex) -> String {
        if node == Snapshot.root { return rootPath }
        var components: [String] = []
        var current = node
        while current != Snapshot.root {
            components.append(name(of: current))
            current = Int(parent[current])
        }
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return base + "/" + components.reversed().joined(separator: "/")
    }

    /// the size a node shows: bytes on disk, or file length
    public func size(of node: NodeIndex, mode: SizeMode) -> UInt64 {
        mode == .allocated ? allocatedSize[node] : logicalSize[node]
    }

    /// checks the structural invariants (contiguous, in-range children whose
    /// parent points back, sizes summing up, children sorted). Returns a
    /// description of the first violation, or nil. Used by tests and by the
    /// file loader on untrusted input.
    public func validate() -> String? {
        let n = nodeCount
        guard n > 0 else { return "empty snapshot" }
        for array in [firstChild.count, childCount.count, allocatedSize.count, logicalSize.count,
                      nameOffset.count, nameLength.count, kindIndex.count, flags.count] where array != n {
            return "array length mismatch"
        }
        guard parent[0] == 0 else { return "root parent must be 0" }
        var seenAsChild = [Bool](repeating: false, count: n)
        for node in 0 ..< n {
            let first = Int(firstChild[node]), count = Int(childCount[node])
            if count > 0 && !flags[node].contains(.directory) { return "node \(node): non-directory with children" }
            guard first >= 0, count >= 0, first + count <= n else { return "node \(node): child range out of bounds" }
            if count > 0 && first <= node { return "node \(node): children must come after their parent" }
            var allocatedSum: UInt64 = 0, logicalSum: UInt64 = 0
            for child in first ..< first + count {
                if seenAsChild[child] { return "node \(child): has two parents" }
                seenAsChild[child] = true
                if Int(parent[child]) != node { return "node \(child): parent mismatch" }
                let (a, o1) = allocatedSum.addingReportingOverflow(allocatedSize[child])
                let (l, o2) = logicalSum.addingReportingOverflow(logicalSize[child])
                if o1 || o2 { return "node \(node): size overflow" }
                allocatedSum = a; logicalSum = l
                if child > first && allocatedSize[child] > allocatedSize[child - 1] {
                    return "node \(node): children not sorted by allocated size"
                }
            }
            if flags[node].contains(.directory) && (allocatedSize[node] != allocatedSum || logicalSize[node] != logicalSum) {
                return "node \(node): directory size is not the sum of its children"
            }
            if Int(nameOffset[node]) + Int(nameLength[node]) > nameBytes.count { return "node \(node): name out of bounds" }
            if Int(kindIndex[node]) >= kinds.count { return "node \(node): kind out of bounds" }
        }
        for node in 1 ..< n where !seenAsChild[node] { return "node \(node): unreachable" }
        return nil
    }
}

public enum SizeMode: String, Sendable, Codable {
    /// bytes on disk (default; what deleting frees, cloud placeholders ~0)
    case allocated
    /// file lengths
    case logical
}
