//
//  SnapshotFileTests.swift
//  DIXCoreTests
//
//  The .dixsnap reader and writer: round trips, and a loader that must never
//  crash on truncated, corrupted or hand-crafted hostile files.
//
//  GPL v3
//

import Foundation
import Testing
@testable import DIXCore

/// deterministic PRNG (SplitMix64), so failures reproduce
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A random valid snapshot with `count` nodes.
func randomSnapshot(count: Int, seed: UInt64) -> Snapshot {
    var rng = SplitMix(state: seed)
    // a random tree as parent links, each node's parent chosen among earlier directories
    struct Node { var name: [UInt8]; var size: UInt64; var logical: UInt64; var isDir: Bool; var children: [Int] = []; var flags: NodeFlags; var kind: UInt16 }
    var nodes = [Node(name: Array("root".utf8), size: 0, logical: 0, isDir: true, flags: .directory, kind: 0)]
    var directories = [0]
    for i in 1 ..< count {
        let isDir = Int.random(in: 0 ..< 4, using: &rng) == 0
        let parent = directories[Int.random(in: 0 ..< directories.count, using: &rng)]
        let nameLength = Int.random(in: 1 ... 12, using: &rng)
        let name = (0 ..< nameLength).map { _ in UInt8.random(in: 0x21 ... 0xFE, using: &rng) }
        let size = isDir ? 0 : UInt64.random(in: 0 ... 1 << 20, using: &rng) & ~4095
        var flags: NodeFlags = isDir ? .directory : []
        if !isDir && Int.random(in: 0 ..< 10, using: &rng) == 0 { flags.insert(.cloudPlaceholder) }
        nodes.append(Node(name: name + Array("\(i)".utf8), size: size, logical: size / 2, isDir: isDir,
                          flags: flags, kind: isDir ? 0 : UInt16.random(in: 1 ... 3, using: &rng)))
        nodes[parent].children.append(i)
        if isDir { directories.append(i) }
    }
    // subtree sums (children have larger indexes than parents)
    for i in stride(from: count - 1, through: 0, by: -1) where nodes[i].isDir {
        nodes[i].size = nodes[i].children.reduce(0) { $0 + nodes[$1].size }
        nodes[i].logical = nodes[i].children.reduce(0) { $0 + nodes[$1].logical }
    }
    let sizes = nodes.map(\.size), names = nodes.map(\.name)
    for i in 0 ..< count {
        nodes[i].children.sort { a, b in
            sizes[a] != sizes[b] ? sizes[a] > sizes[b] : names[a].lexicographicallyPrecedes(names[b])
        }
    }
    // BFS layout
    var order = [0], index = [Int](repeating: 0, count: count)
    var head = 0
    while head < order.count {
        let n = order[head]; index[n] = head; head += 1
        order.append(contentsOf: nodes[n].children)
    }
    var parent = [UInt32](repeating: 0, count: count), firstChild = parent, childCount = parent
    var allocated = [UInt64](repeating: 0, count: count), logical = allocated
    var nameOffset = [UInt32](repeating: 0, count: count), nameLength = [UInt16](repeating: 0, count: count)
    var kindIndex = [UInt16](repeating: 0, count: count), flags = [NodeFlags](repeating: [], count: count)
    var nameBytes: [UInt8] = []
    for (position, n) in order.enumerated() {
        let node = nodes[n]
        allocated[position] = node.size
        logical[position] = node.logical
        nameOffset[position] = UInt32(nameBytes.count)
        nameLength[position] = UInt16(node.name.count)
        nameBytes += node.name
        kindIndex[position] = node.kind
        flags[position] = node.flags
        childCount[position] = UInt32(node.children.count)
        firstChild[position] = UInt32(node.children.first.map { index[$0] } ?? 0)
        for c in node.children { parent[index[c]] = UInt32(position) }
    }
    return Snapshot(rootPath: "/fuzz/root", scanDate: Date(timeIntervalSince1970: 1_700_000_000),
                    volume: VolumeInfo(name: "Disk", mountPath: "/", totalCapacity: 1 << 40, availableCapacity: 1 << 39),
                    parent: parent, firstChild: firstChild, childCount: childCount,
                    allocatedSize: allocated, logicalSize: logical, nameOffset: nameOffset, nameLength: nameLength,
                    kindIndex: kindIndex, flags: flags, nameBytes: nameBytes,
                    kinds: [FileKind(identifier: "public.folder", name: "Folder"),
                            FileKind(identifier: "public.data", name: "Document"),
                            FileKind(identifier: "", name: "XYZ File"),
                            FileKind(identifier: "public.jpeg", name: "JPEG image")])
}

/// a chain of directories `depth` deep with one file at the bottom
func chainSnapshot(depth: Int) -> Snapshot {
    let n = depth + 1
    var parent = [UInt32](repeating: 0, count: n), firstChild = parent, childCount = parent
    for i in 0 ..< depth {
        firstChild[i] = UInt32(i + 1); childCount[i] = 1; parent[i + 1] = UInt32(i)
    }
    var flags = [NodeFlags](repeating: .directory, count: n)
    flags[depth] = []
    return Snapshot(rootPath: "/deep", scanDate: Date(timeIntervalSince1970: 0), volume: nil,
                    parent: parent, firstChild: firstChild, childCount: childCount,
                    allocatedSize: [UInt64](repeating: 4096, count: n), logicalSize: [UInt64](repeating: 10, count: n),
                    nameOffset: [UInt32](repeating: 0, count: n), nameLength: [UInt16](repeating: 1, count: n),
                    kindIndex: [UInt16](repeating: 0, count: n), flags: flags, nameBytes: Array("d".utf8),
                    kinds: [FileKind(identifier: "public.folder", name: "Folder")])
}

private func expectEqual(_ a: Snapshot, _ b: Snapshot) {
    #expect(a.rootPath == b.rootPath && a.scanDate == b.scanDate && a.volume == b.volume)
    #expect(a.parent == b.parent && a.firstChild == b.firstChild && a.childCount == b.childCount)
    #expect(a.allocatedSize == b.allocatedSize && a.logicalSize == b.logicalSize)
    #expect(a.nameOffset == b.nameOffset && a.nameLength == b.nameLength && a.nameBytes == b.nameBytes)
    #expect(a.kindIndex == b.kindIndex && a.flags == b.flags && a.kinds == b.kinds)
}

@Suite struct SnapshotFileTests {
    @Test func roundTrip() throws {
        for (count, seed) in [(1, 1), (2, 2), (50, 3), (5000, 4)] as [(Int, UInt64)] {
            let s = randomSnapshot(count: count, seed: seed)
            #expect(s.validate() == nil)
            let data = try s.fileData()
            #expect(data.count % 8 == 0)
            expectEqual(try Snapshot(fileData: data), s)
            // and through a real file
            let url = URL(fileURLWithPath: NSTemporaryDirectory() + "rt-\(getpid())-\(seed).dixsnap")
            try s.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            expectEqual(try Snapshot(contentsOf: url), s)
        }
        var noVolume = randomSnapshot(count: 10, seed: 9)
        noVolume.volume = nil
        expectEqual(try Snapshot(fileData: noVolume.fileData()), noVolume)
    }

    @Test func writingAnInvalidSnapshotThrows() {
        var s = randomSnapshot(count: 20, seed: 5)
        s.allocatedSize[0] += 1
        #expect(throws: SnapshotFileError.self) { try s.fileData() }
    }

    @Test func deepChainsLoadWithoutRecursion() throws {
        let s = chainSnapshot(depth: 200_000)
        let loaded = try Snapshot(fileData: s.fileData())
        #expect(loaded.nodeCount == 200_001)
        #expect(loaded.path(of: 200_000).count == 2 * 200_000 + "/deep".count)
    }

    @Test func notASnapshot() {
        #expect(throws: SnapshotFileError.notASnapshot) { try Snapshot(fileData: Data()) }
        #expect(throws: SnapshotFileError.notASnapshot) { try Snapshot(fileData: Data("hello".utf8)) }
        #expect(throws: SnapshotFileError.notASnapshot) { try Snapshot(fileData: Data(repeating: 0, count: 4096)) }
    }

    /// Every truncation of a small file throws (never traps).
    @Test func everyTruncationThrows() throws {
        let data = try randomSnapshot(count: 40, seed: 11).fileData()
        for length in 0 ..< data.count {
            #expect(throws: SnapshotFileError.self) { try Snapshot(fileData: data.prefix(length)) }
        }
        // and trailing garbage too
        #expect(throws: SnapshotFileError.self) { try Snapshot(fileData: data + Data([0])) }
    }

    /// Random byte flips, splices and length changes: the loader either throws
    /// or returns a snapshot that validates. It never traps.
    @Test func fuzzCorruption() throws {
        var rng = SplitMix(state: 0xD1C5)
        let originals = try [randomSnapshot(count: 1, seed: 21), randomSnapshot(count: 30, seed: 22),
                             randomSnapshot(count: 400, seed: 23)].map { try $0.fileData() }
        var accepted = 0, rejected = 0
        let iterations = ProcessInfo.processInfo.environment["DIX_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 30_000
        for iteration in 0 ..< iterations {
            var bytes = [UInt8](originals[iteration % originals.count])
            switch Int.random(in: 0 ..< 6, using: &rng) {
            case 0:     // flip 1-8 random bytes
                for _ in 0 ..< Int.random(in: 1 ... 8, using: &rng) {
                    bytes[Int.random(in: 0 ..< bytes.count, using: &rng)] = UInt8.random(in: 0 ... 255, using: &rng)
                }
            case 1:     // flip one bit in the header or section table
                let i = Int.random(in: 0 ..< min(bytes.count, 64 + 24 * 12), using: &rng)
                bytes[i] ^= 1 << UInt8.random(in: 0 ..< 8, using: &rng)
            case 2:     // write an extreme integer somewhere
                let i = Int.random(in: 0 ..< bytes.count - 8, using: &rng) & ~3
                let value: UInt64 = [0, 1, .max, .max / 2, UInt64(UInt32.max), UInt64(UInt32.max) + 1, 1 << 40].randomElement(using: &rng)!
                withUnsafeBytes(of: value) { bytes.replaceSubrange(i ..< i + 8, with: $0) }
            case 3:     // truncate, keeping the header's length field consistent
                let length = Int.random(in: 0 ..< bytes.count, using: &rng)
                bytes = Array(bytes.prefix(length))
                if bytes.count >= 32 {
                    withUnsafeBytes(of: UInt64(bytes.count)) { bytes.replaceSubrange(24 ..< 32, with: $0) }
                }
            case 4:     // corrupt a node array but leave the framing intact
                let i = Int.random(in: 64 + 24 * 12 ..< bytes.count, using: &rng)
                bytes[i] = UInt8.random(in: 0 ... 255, using: &rng)
            default:    // splice: duplicate a random range
                let a = Int.random(in: 0 ..< bytes.count, using: &rng)
                let b = min(bytes.count, a + Int.random(in: 1 ... 64, using: &rng))
                bytes.insert(contentsOf: bytes[a ..< b], at: a)
                if Bool.random(using: &rng) {
                    withUnsafeBytes(of: UInt64(bytes.count)) { bytes.replaceSubrange(24 ..< 32, with: $0) }
                }
            }
            do {
                let s = try Snapshot(fileData: Data(bytes))
                #expect(s.validate() == nil)
                _ = s.summary
                _ = s.path(of: s.nodeCount - 1)
                accepted += 1
            } catch is SnapshotFileError {
                rejected += 1
            }
        }
        #expect(rejected > iterations * 2 / 3)
        print("fuzz: \(accepted) accepted (valid after corruption), \(rejected) rejected")
    }

    /// Hand-crafted lies in the header: huge node counts, sections pointing
    /// past the end or overflowing, huge string and kind counts.
    @Test func hostileHeaders() throws {
        let good = [UInt8](try randomSnapshot(count: 10, seed: 31).fileData())
        func patched(_ offset: Int, _ value: UInt64, size: Int = 8) -> Data {
            var b = good
            withUnsafeBytes(of: value) { b.replaceSubrange(offset ..< offset + size, with: $0.prefix(size)) }
            return Data(b)
        }
        let sectionCount = Int(good[12])
        var hostile: [Data] = [
            patched(16, UInt64(UInt32.max)),            // node count far beyond the file
            patched(16, 0),                             // zero nodes
            patched(16, .max),
            patched(12, UInt64(UInt32.max), size: 4),   // section count
            patched(12, 0, size: 4),
            patched(8, 2, size: 4),                     // version
        ]
        for s in 0 ..< sectionCount {
            let entry = 64 + 24 * s
            hostile.append(patched(entry + 8, .max))                    // offset
            hostile.append(patched(entry + 8, UInt64(good.count)))      // offset at the end
            hostile.append(patched(entry + 16, .max))                   // length
            hostile.append(patched(entry + 16, .max - 7))
            hostile.append(patched(entry + 4, 0, size: 4))              // element size 0
            hostile.append(patched(entry + 4, 3, size: 4))
            hostile.append(patched(entry, 0x4B4E_4B4E, size: 4))        // tag renamed: section missing
        }
        // the META section's first string length, and the kind count
        let meta = Int(UInt64(littleEndian: good[(64 + 8) ..< (64 + 16)].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }))
        hostile.append(patched(meta, UInt64(UInt32.max), size: 4))
        let kind = Int(UInt64(littleEndian: good[(64 + 24 + 8) ..< (64 + 24 + 16)].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }))
        hostile.append(patched(kind, UInt64(UInt32.max), size: 4))
        hostile.append(patched(kind, 0, size: 4))
        for data in hostile {
            #expect(throws: SnapshotFileError.self) { try Snapshot(fileData: data) }
        }
    }

    @Test func summaryCountsFlags() {
        let s = randomSnapshot(count: 300, seed: 41)
        let summary = s.summary
        #expect(summary.files + summary.directories == 300)
        #expect(summary.allocatedSize == s.allocatedSize[0])
        #expect(summary.cloudFiles == s.flags.filter { $0.contains(.cloudPlaceholder) }.count)
    }

    @Test func loadingAMillionNodesIsFast() throws {
        let s = randomSnapshot(count: 1_000_000, seed: 51)
        let data = try s.fileData()
        let start = Date()
        let loaded = try Snapshot(fileData: data)
        let elapsed = Date().timeIntervalSince(start)
        #expect(loaded.nodeCount == 1_000_000)
        print(String(format: "load 1M nodes (%d bytes, incl. validate): %.1f ms", data.count, elapsed * 1000))
    }
}
