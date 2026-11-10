//
//  SnapshotCompressionTests.swift
//  DIXCoreTests
//
//  Compressed .dixsnap files (DIXSNAPZ): round trips, and a loader that
//  never crashes or over-allocates on truncated, corrupted or lying files.
//
//  GPL v3
//

import Foundation
import Testing
@testable import DIXCore

private func sameSnapshot(_ a: Snapshot, _ b: Snapshot) -> Bool {
    a.rootPath == b.rootPath && a.scanDate == b.scanDate && a.volume == b.volume
        && a.parent == b.parent && a.firstChild == b.firstChild && a.childCount == b.childCount
        && a.allocatedSize == b.allocatedSize && a.logicalSize == b.logicalSize
        && a.nameOffset == b.nameOffset && a.nameLength == b.nameLength && a.nameBytes == b.nameBytes
        && a.kindIndex == b.kindIndex && a.flags == b.flags && a.kinds == b.kinds && a.hardLinks == b.hardLinks
}

private func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
    bytes[at ..< at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
}

private func patched(_ bytes: [UInt8], _ offset: Int, _ value: UInt64, size: Int) -> Data {
    var b = bytes
    withUnsafeBytes(of: value) { b.replaceSubrange(offset ..< offset + size, with: $0.prefix(size)) }
    return Data(b)
}

/// a snapshot whose names are random bytes: some chunks will not compress
private func incompressibleSnapshot(nodes: Int) -> Snapshot {
    var s = randomSnapshot(count: nodes, seed: 99)
    var rng = SplitMix(state: 7)
    var names: [UInt8] = []
    for i in 0 ..< s.nodeCount {
        s.nameOffset[i] = UInt32(names.count)
        s.nameLength[i] = 200
        names.append(contentsOf: (0 ..< 200).map { _ in UInt8.random(in: 0 ... 255, using: &rng) })
    }
    s.nameBytes = names
    // equal names cannot break sibling order here: sizes decide first, and
    // random 200-byte names never tie; but re-sorting would be needed if they
    // did, so check
    return s
}

@Suite struct SnapshotCompressionTests {
    @Test func roundTrips() throws {
        for (count, seed) in [(1, 1), (2, 2), (50, 3), (5000, 4), (300_000, 5)] as [(Int, UInt64)] {
            let s = randomSnapshot(count: count, seed: seed)
            let plain = try s.fileData()
            let packed = try s.fileData(compression: .lzfse)
            #expect(Array(packed.prefix(8)) == Array("DIXSNAPZ".utf8))
            #expect(packed.count < plain.count || count < 50)
            #expect(sameSnapshot(try Snapshot(fileData: packed), s))
            // the plain file inside is exactly the uncompressed format
            let inner = try packed.withUnsafeBytes { try SnapshotContainer.decompress($0) }
            #expect(Data(inner) == plain)
        }
    }

    @Test func writeCompressesByDefault() throws {
        let s = randomSnapshot(count: 20_000, seed: 6)
        let dir = NSTemporaryDirectory() + "dixz-\(getpid())-\(UInt32.random(in: 0 ... .max))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let packedURL = URL(fileURLWithPath: dir + "/z.dixsnap"), plainURL = URL(fileURLWithPath: dir + "/p.dixsnap")
        try s.write(to: packedURL)
        try s.write(to: plainURL, compression: .none)
        let packed = try Data(contentsOf: packedURL), plain = try Data(contentsOf: plainURL)
        #expect(Array(packed.prefix(8)) == Array("DIXSNAPZ".utf8))
        #expect(Array(plain.prefix(8)) == Array("DIXSNAP1".utf8))
        #expect(packed == (try s.fileData(compression: .lzfse)))
        #expect(plain == (try s.fileData()))
        #expect(sameSnapshot(try Snapshot(contentsOf: packedURL), s))
        #expect(sameSnapshot(try Snapshot(contentsOf: plainURL), s))
        print("20k nodes: \(plain.count) B plain, \(packed.count) B compressed")
    }

    @Test func incompressibleChunksAreStored() throws {
        let s = incompressibleSnapshot(nodes: 60_000)      // ~12 MB of random names
        #expect(s.validate() == nil)
        let packed = [UInt8](try s.fileData(compression: .lzfse))
        let count = Int(u32(packed, 28))
        let encodings = (0 ..< count).map { u32(packed, 32 + 8 * $0 + 4) }
        #expect(encodings.contains(SnapshotContainer.encodingStored))
        #expect(encodings.contains(SnapshotContainer.encodingLZFSE))
        #expect(sameSnapshot(try Snapshot(fileData: Data(packed)), s))
    }

    @Test func constantDataStaysWithinTheRatioCap() throws {
        // megabytes of identical sizes, flags and names: LZFSE's best case,
        // still within what the reader accepts
        let s = chainSnapshot(depth: 400_000)
        let packed = try s.fileData(compression: .lzfse)
        #expect(packed.count * 4 < (try s.fileData()).count)
        #expect(sameSnapshot(try Snapshot(fileData: packed), s))
    }

    @Test func hardLinksSurviveCompression() throws {
        var s = randomSnapshot(count: 200, seed: 8)
        // every file a hard link whose other links are elsewhere (each its own keeper)
        let files = (0 ..< s.nodeCount).filter { !s.isDirectory($0) }
        s.hardLinks = files.map { HardLink(node: UInt32($0), device: 3, fileID: UInt64($0) * 1000) }
        #expect(s.hardLinks.count > 100)
        #expect(s.validate() == nil)
        #expect(sameSnapshot(try Snapshot(fileData: s.fileData(compression: .lzfse)), s))
        #expect(sameSnapshot(try Snapshot(fileData: s.fileData()), s))
    }

    @Test func everyTruncationThrows() throws {
        let data = try randomSnapshot(count: 300, seed: 11).fileData(compression: .lzfse)
        for length in 0 ..< data.count {
            #expect(throws: SnapshotFileError.self) { try Snapshot(fileData: data.prefix(length)) }
        }
        #expect(throws: SnapshotFileError.self) { try Snapshot(fileData: data + Data([0])) }
    }

    /// Lies in the container header and chunk table.
    @Test func hostileContainers() throws {
        let good = [UInt8](try randomSnapshot(count: 2000, seed: 31).fileData(compression: .lzfse))
        let count = Int(u32(good, 28))
        var hostile: [Data] = [
            patched(good, 8, 2, size: 4),                                   // version
            patched(good, 12, 9, size: 4),                                  // algorithm
            patched(good, 16, UInt64(SnapshotContainer.maxPlainLength) + 1, size: 8),
            patched(good, 16, 1 << 40, size: 8),                            // a terabyte from a few KB
            patched(good, 16, .max, size: 8),
            patched(good, 16, 0, size: 8),
            patched(good, 16, 63, size: 8),
            patched(good, 24, 0, size: 4),                                  // chunk size
            patched(good, 24, 1, size: 4),
            patched(good, 24, UInt64(UInt32.max), size: 4),
            patched(good, 28, 0, size: 4),                                  // chunk count
            patched(good, 28, UInt64(UInt32.max), size: 4),
            patched(good, 28, UInt64(count + 1), size: 4),
        ]
        for i in 0 ..< count {
            let entry = 32 + 8 * i
            hostile.append(patched(good, entry, 0, size: 4))                // stored length
            hostile.append(patched(good, entry, UInt64(UInt32.max), size: 4))
            hostile.append(patched(good, entry, UInt64(u32(good, entry) + 1), size: 4))
            hostile.append(patched(good, entry + 4, 1, size: 4))            // "stored" with a compressed length
            hostile.append(patched(good, entry + 4, 7, size: 4))            // unknown encoding
        }
        // a chunk claiming more than the ratio cap: plain length far beyond 4096x the stored bytes
        var tiny = [UInt8](good.prefix(32))
        withUnsafeBytes(of: UInt64(4 << 20).littleEndian) { tiny.replaceSubrange(16 ..< 24, with: $0) }
        withUnsafeBytes(of: UInt32(1).littleEndian) { tiny.replaceSubrange(28 ..< 32, with: $0) }
        tiny += [100, 0, 0, 0, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 100)
        hostile.append(Data(tiny))
        // a container inside a container
        var nested = try randomSnapshot(count: 10, seed: 32).fileData(compression: .lzfse)
        let inner = [UInt8](nested)
        var wrapper = [UInt8](good.prefix(16))
        withUnsafeBytes(of: UInt64(inner.count).littleEndian) { wrapper.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(SnapshotContainer.chunkSize).littleEndian) { wrapper.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(1).littleEndian) { wrapper.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(inner.count).littleEndian) { wrapper.append(contentsOf: $0) }
        withUnsafeBytes(of: SnapshotContainer.encodingStored.littleEndian) { wrapper.append(contentsOf: $0) }
        nested = Data(wrapper + inner)
        hostile.append(nested)
        for data in hostile {
            #expect(throws: SnapshotFileError.self) { try Snapshot(fileData: data) }
        }
    }

    /// Random corruption of compressed files: the loader throws or returns a
    /// valid snapshot. It never traps.
    @Test func fuzzCompressedCorruption() throws {
        var rng = SplitMix(state: 0x2C0F)
        let originals = try [randomSnapshot(count: 1, seed: 21), randomSnapshot(count: 30, seed: 22),
                             randomSnapshot(count: 400, seed: 23), randomSnapshot(count: 120_000, seed: 24)]
            .map { [UInt8](try $0.fileData(compression: .lzfse)) }
        var accepted = 0, rejected = 0
        let iterations = ProcessInfo.processInfo.environment["DIX_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 6_000
        for iteration in 0 ..< iterations {
            // the big one (several chunks) less often: it is slow to decode
            var bytes = originals[iteration % 10 == 9 ? 3 : iteration % 3]
            let tableEnd = min(bytes.count, 32 + 8 * Int(u32(bytes, 28)))
            switch Int.random(in: 0 ..< 6, using: &rng) {
            case 0:     // flip 1-8 random bytes anywhere
                for _ in 0 ..< Int.random(in: 1 ... 8, using: &rng) {
                    bytes[Int.random(in: 0 ..< bytes.count, using: &rng)] = UInt8.random(in: 0 ... 255, using: &rng)
                }
            case 1:     // flip a bit in the header or chunk table
                let i = Int.random(in: 0 ..< tableEnd, using: &rng)
                bytes[i] ^= 1 << UInt8.random(in: 0 ..< 8, using: &rng)
            case 2:     // an extreme integer in the header or table
                let i = Int.random(in: 0 ..< (tableEnd - 4) / 4, using: &rng) * 4
                let value: UInt32 = [0, 1, .max, .max / 2, 4 << 20, 1 << 16].randomElement(using: &rng)!
                withUnsafeBytes(of: value) { bytes.replaceSubrange(i ..< i + 4, with: $0) }
            case 3:     // truncate
                bytes = Array(bytes.prefix(Int.random(in: 0 ..< bytes.count, using: &rng)))
            case 4:     // corrupt the compressed payload only
                if bytes.count > tableEnd {
                    for _ in 0 ..< Int.random(in: 1 ... 4, using: &rng) {
                        bytes[Int.random(in: tableEnd ..< bytes.count, using: &rng)] = UInt8.random(in: 0 ... 255, using: &rng)
                    }
                }
            default:    // splice a range into the payload, and fix up the first chunk's length
                let a = Int.random(in: tableEnd ..< max(tableEnd + 1, bytes.count), using: &rng)
                let b = min(bytes.count, a + Int.random(in: 1 ... 64, using: &rng))
                if a < b {
                    bytes.insert(contentsOf: bytes[a ..< b], at: a)
                    if tableEnd >= 40 {
                        let first = u32(bytes, 32) &+ UInt32(b - a)
                        withUnsafeBytes(of: first) { bytes.replaceSubrange(32 ..< 36, with: $0) }
                    }
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
        #expect(rejected > iterations / 2)
        print("compressed fuzz: \(accepted) accepted (valid after corruption), \(rejected) rejected")
    }
}
