//
//  Export.swift
//  dix-scan
//
//  dix-scan --export tsv <snap.dixsnap> -o out.tsv: one row per node, depth
//  first (a folder, then its children largest first), with a header row:
//
//    path        absolute path
//    depth       0 for the root
//    allocated   bytes on disk (folders: subtree total)
//    logical     file length (folders: subtree total)
//    kind        kind name ("Folder", "JPEG image", ...)
//    flags       7 letters, "-" when unset: d directory, p package, l symlink,
//                c cloud placeholder, h hard-link duplicate, m mount point,
//                u unreadable
//    file_count  files in the subtree (1 for a file, 0 for an empty folder)
//
//  A field containing a tab, newline, carriage return or double quote is
//  quoted ("..." with quotes doubled), as DuckDB, pandas and Python's csv
//  module read it. Names that are not valid UTF-8 are written with U+FFFD
//  replacement characters, so the file is always valid UTF-8.
//
//  GPL v3
//

import Foundation
import DIXCore

func flagString(_ f: NodeFlags) -> String {
    var s = ""
    for (flag, c) in [(NodeFlags.directory, "d"), (.package, "p"), (.symlink, "l"), (.cloudPlaceholder, "c"),
                      (.hardLinkDuplicate, "h"), (.mountPoint, "m"), (.unreadable, "u")] {
        s += f.contains(flag) ? c : "-"
    }
    return s
}

func exportTSV(_ s: Snapshot, to path: String) throws {
    let n = s.nodeCount
    // files per subtree: children come after their parents, so one backward pass
    var fileCount = [UInt32](repeating: 0, count: n)
    for i in 0 ..< n where !s.isDirectory(i) { fileCount[i] = 1 }
    for i in stride(from: n - 1, to: 0, by: -1) { fileCount[Int(s.parent[i])] &+= fileCount[i] }

    guard FileManager.default.createFile(atPath: path, contents: nil),
          let handle = FileHandle(forWritingAtPath: path) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
    }
    defer { try? handle.close() }
    var out: [UInt8] = []
    out.reserveCapacity(1 << 22)
    func flush() throws {
        try handle.write(contentsOf: out)
        out.removeAll(keepingCapacity: true)
    }

    func needsQuotes<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8 {
        bytes.contains { $0 == 9 || $0 == 10 || $0 == 13 || $0 == 34 }
    }
    func field<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        if needsQuotes(bytes) {
            out.append(34)
            for b in bytes {
                out.append(b)
                if b == 34 { out.append(34) }
            }
            out.append(34)
        } else {
            out.append(contentsOf: bytes)
        }
    }
    let kindNames = s.kinds.map { Array($0.name.utf8) }
    let flagNames = (0 ..< 128).map { Array(flagString(NodeFlags(rawValue: UInt16($0))).utf8) }

    out.append(contentsOf: Array("path\tdepth\tallocated\tlogical\tkind\tflags\tfile_count\n".utf8))
    // depth-first; `pathBuffer` holds the current path, each stack entry knows
    // how long its parent's path was
    var pathBuffer = Array(s.rootPath.utf8)
    if pathBuffer.count > 1 && pathBuffer.last == UInt8(ascii: "/") { pathBuffer.removeLast() }
    let rootLength = pathBuffer.count
    var stack: [(node: Int, depth: Int, parentLength: Int)] = [(0, 0, rootLength)]
    var nameScratch: [UInt8] = []
    while let (node, depth, parentLength) = stack.popLast() {
        if node != 0 {
            pathBuffer.removeSubrange(parentLength...)
            if pathBuffer.last != UInt8(ascii: "/") { pathBuffer.append(UInt8(ascii: "/")) }
            let start = Int(s.nameOffset[node])
            let name = s.nameBytes[start ..< start + Int(s.nameLength[node])]
            if name.allSatisfy({ $0 < 0x80 }) {
                pathBuffer.append(contentsOf: name)
            } else {
                // valid UTF-8 comes back unchanged; anything else gets U+FFFD
                nameScratch = Array(String(decoding: name, as: UTF8.self).utf8)
                pathBuffer.append(contentsOf: nameScratch)
            }
        }
        field(pathBuffer)
        out.append(9)
        out.append(contentsOf: String(depth).utf8)
        out.append(9)
        out.append(contentsOf: String(s.allocatedSize[node]).utf8)
        out.append(9)
        out.append(contentsOf: String(s.logicalSize[node]).utf8)
        out.append(9)
        field(kindNames[Int(s.kindIndex[node])])
        out.append(9)
        out.append(contentsOf: flagNames[Int(s.flags[node].rawValue & 0x7F)])
        out.append(9)
        out.append(contentsOf: String(fileCount[node]).utf8)
        out.append(10)
        if out.count > 1 << 22 { try flush() }
        let length = pathBuffer.count
        for child in s.children(of: node).reversed() { stack.append((child, depth + 1, length)) }
    }
    try flush()
}
