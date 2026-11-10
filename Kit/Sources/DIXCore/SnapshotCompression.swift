//
//  SnapshotCompression.swift
//  DIXCore
//
//  Compressed .dixsnap files: a plain DIXSNAP1 file, cut into 4 MiB chunks,
//  each compressed with LZFSE (Apple's Compression framework) on its own, so
//  both writing and reading run on all cores. Snapshots shrink about 7x
//  (names, sorted sizes and runs of equal flags compress well).
//
//    offset  size  field
//    0       8     magic "DIXSNAPZ"
//    8       4     container version (1)
//    12      4     algorithm (1 = LZFSE)
//    16      8     U: length of the plain DIXSNAP1 file inside
//    24      4     C: chunk size; every chunk but the last holds exactly C bytes
//                  of the plain file, the last holds the rest
//    28      4     K: chunk count, = ceil(U / C)
//    32      8*K   chunk table: { u32 stored length, u32 encoding }, encoding
//                  0 = LZFSE, 1 = stored as is
//    32+8K   ...   the chunks, back to back; the file ends with the last one
//
//  The reader trusts nothing: U is capped absolutely (maxPlainLength) and by
//  the file size (a chunk may claim at most maxChunkRatio times its stored
//  length, which LZFSE never reaches: about 1600x on constant data), the
//  table must account for every byte of the file, each chunk must decode to
//  exactly its claimed length, and the plain file inside then goes through
//  the usual DIXSNAP1 checks and validate(). The writer stores a chunk as is
//  if compressing it does not help or would exceed maxChunkRatio.
//
//  GPL v3
//

import Foundation
import Compression

/// Raw pointers handed to concurrentPerform workers, each of which touches
/// only its own disjoint range.
private struct SharedPointers: @unchecked Sendable {
    var a: UnsafeMutableRawPointer
    var b: UnsafeMutableRawPointer
    var flags: UnsafeMutablePointer<Int>
}

enum SnapshotContainer {
    static let magic: [UInt8] = Array("DIXSNAPZ".utf8)
    static let version: UInt32 = 1
    static let algorithmLZFSE: UInt32 = 1
    static let headerSize = 32
    static let tableEntrySize = 8
    static let chunkSize = 4 << 20
    static let minChunkSize = 64 << 10, maxChunkSize = 64 << 20
    /// the largest plain file a compressed file may claim (16 GiB, about
    /// 400 million nodes)
    static let maxPlainLength = 1 << 34
    static let maxChunkRatio = 4096
    static let encodingLZFSE: UInt32 = 0, encodingStored: UInt32 = 1

    static func isCompressed(_ raw: UnsafeRawBufferPointer) -> Bool {
        raw.count >= 8 && raw.prefix(8).elementsEqual(magic)
    }

    /// The plain DIXSNAP1 bytes inside a compressed file.
    static func decompress(_ raw: UnsafeRawBufferPointer) throws -> [UInt8] {
        func malformed(_ why: String) -> SnapshotFileError { .malformed("compressed file: " + why) }
        guard raw.count >= headerSize, isCompressed(raw) else { throw SnapshotFileError.notASnapshot }
        func u32(_ at: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
        func u64(_ at: Int) -> UInt64 { UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt64.self)) }
        let version = u32(8)
        guard version == Self.version else { throw SnapshotFileError.unsupportedVersion(version) }
        guard u32(12) == algorithmLZFSE else { throw malformed("unknown algorithm") }
        let plain64 = u64(16), chunk = Int(u32(24)), count = Int(u32(28))
        guard plain64 >= UInt64(SnapshotFormat.headerSize), plain64 <= UInt64(maxPlainLength) else {
            throw malformed("plain length \(plain64) out of range")
        }
        let plain = Int(plain64)
        guard chunk >= minChunkSize, chunk <= maxChunkSize else { throw malformed("bad chunk size") }
        guard count == (plain + chunk - 1) / chunk else { throw malformed("chunk count does not match the length") }
        guard count <= (raw.count - headerSize) / tableEntrySize else { throw malformed("chunk table out of bounds") }
        let payloadStart = headerSize + count * tableEntrySize

        // the table: every byte of the file accounted for, every claim bounded
        var offsets = [Int](repeating: 0, count: count)
        var stored = [Int](repeating: 0, count: count)
        var compressed = [Bool](repeating: false, count: count)
        var cursor = payloadStart
        for i in 0 ..< count {
            let length = Int(u32(headerSize + i * tableEntrySize))
            let encoding = u32(headerSize + i * tableEntrySize + 4)
            let expected = min(chunk, plain - i * chunk)
            guard length <= raw.count - cursor else { throw malformed("chunk \(i) past the end of the file") }
            switch encoding {
            case encodingStored:
                guard length == expected else { throw malformed("stored chunk \(i) has the wrong length") }
            case encodingLZFSE:
                guard length > 0, expected / maxChunkRatio <= length else { throw malformed("chunk \(i) claims too much") }
                compressed[i] = true
            default:
                throw malformed("chunk \(i): unknown encoding")
            }
            offsets[i] = cursor
            stored[i] = length
            cursor += length
        }
        guard cursor == raw.count else { throw malformed("\(raw.count - cursor) bytes after the last chunk") }

        var failed = [Int](repeating: 0, count: count)
        let (offsetsOf, storedOf, isCompressed) = (offsets, stored, compressed)
        let output = [UInt8](unsafeUninitializedCapacity: plain) { buffer, initialized in
            failed.withUnsafeMutableBufferPointer { failures in
                let shared = SharedPointers(a: UnsafeMutableRawPointer(buffer.baseAddress!),
                                            b: UnsafeMutableRawPointer(mutating: raw.baseAddress!),
                                            flags: failures.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: count) { i in
                    let expected = min(chunk, plain - i * chunk)
                    let target = shared.a + i * chunk
                    let source = UnsafeRawPointer(shared.b + offsetsOf[i])
                    if !isCompressed[i] {
                        target.copyMemory(from: source, byteCount: expected)
                        return
                    }
                    let produced = compression_decode_buffer(target.assumingMemoryBound(to: UInt8.self), expected,
                                                             source.assumingMemoryBound(to: UInt8.self), storedOf[i],
                                                             nil, COMPRESSION_LZFSE)
                    if produced != expected {
                        shared.flags[i] = 1
                        // never leave bytes uninitialized, even on the way to throwing
                        (target + produced).initializeMemory(as: UInt8.self, repeating: 0, count: expected - produced)
                    }
                }
            }
            initialized = plain
        }
        if let bad = failed.firstIndex(of: 1) { throw malformed("chunk \(bad) does not decompress to its length") }
        return output
    }
}

/// Compresses a stream of plain bytes chunk by chunk, a batch of chunks at a
/// time in parallel, and hands out the container's bytes with their offsets
/// (the chunk table is written last, into the space left for it).
private final class ChunkWriter {
    let plainLength: Int
    let chunk = SnapshotContainer.chunkSize
    let count: Int
    let batch: Int
    let staging: UnsafeMutableRawBufferPointer
    let scratch: UnsafeMutableRawBufferPointer
    var filled = 0
    var written = 0           // chunks done
    var position: Int         // file offset of the next chunk
    var table: [UInt8]

    init(plainLength: Int, emit: (Int, UnsafeRawBufferPointer) throws -> Void) throws {
        self.plainLength = plainLength
        count = (plainLength + chunk - 1) / chunk
        batch = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount, count))
        staging = .allocate(byteCount: batch * chunk, alignment: 16)
        scratch = .allocate(byteCount: batch * chunk, alignment: 16)
        table = [UInt8](repeating: 0, count: count * SnapshotContainer.tableEntrySize)
        position = SnapshotContainer.headerSize + table.count

        var header = [UInt8]()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: SnapshotContainer.magic)
        u32(SnapshotContainer.version)
        u32(SnapshotContainer.algorithmLZFSE)
        withUnsafeBytes(of: UInt64(plainLength).littleEndian) { header.append(contentsOf: $0) }
        u32(UInt32(chunk))
        u32(UInt32(count))
        try header.withUnsafeBytes { try emit(0, $0) }
        try table.withUnsafeBytes { try emit(SnapshotContainer.headerSize, $0) }     // placeholder
    }

    deinit {
        staging.deallocate()
        scratch.deallocate()
    }

    func add(_ bytes: UnsafeRawBufferPointer, emit: (Int, UnsafeRawBufferPointer) throws -> Void) throws {
        var rest = bytes
        while !rest.isEmpty {
            let n = min(rest.count, staging.count - filled)
            UnsafeMutableRawBufferPointer(rebasing: staging[filled ..< filled + n]).copyMemory(from: UnsafeRawBufferPointer(rebasing: rest[0 ..< n]))
            filled += n
            rest = UnsafeRawBufferPointer(rebasing: rest[n...])
            if filled == staging.count { try flush(emit: emit) }
        }
    }

    func flush(emit: (Int, UnsafeRawBufferPointer) throws -> Void) throws {
        guard filled > 0 else { return }
        let chunks = (filled + chunk - 1) / chunk
        var sizes = [Int](repeating: 0, count: chunks)
        let chunk = self.chunk, filled = self.filled
        sizes.withUnsafeMutableBufferPointer { out in
            let shared = SharedPointers(a: scratch.baseAddress!, b: staging.baseAddress!, flags: out.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: chunks) { i in
                let length = min(chunk, filled - i * chunk)
                let n = length < 2 ? 0 : compression_encode_buffer(
                    (shared.a + i * chunk).assumingMemoryBound(to: UInt8.self), length - 1,
                    (shared.b + i * chunk).assumingMemoryBound(to: UInt8.self), length, nil, COMPRESSION_LZFSE)
                // 0: did not fit in less than the input; too good: beyond what a reader accepts
                shared.flags[i] = (n == 0 || length / SnapshotContainer.maxChunkRatio > n) ? -1 : n
            }
        }
        for i in 0 ..< chunks {
            let length = min(chunk, filled - i * chunk)
            let piece: UnsafeRawBufferPointer
            let encoding: UInt32
            if sizes[i] < 0 {
                piece = UnsafeRawBufferPointer(rebasing: staging[i * chunk ..< i * chunk + length])
                encoding = SnapshotContainer.encodingStored
            } else {
                piece = UnsafeRawBufferPointer(rebasing: scratch[i * chunk ..< i * chunk + sizes[i]])
                encoding = SnapshotContainer.encodingLZFSE
            }
            try emit(position, piece)
            position += piece.count
            let entry = written * SnapshotContainer.tableEntrySize
            withUnsafeBytes(of: UInt32(piece.count).littleEndian) { table.replaceSubrange(entry ..< entry + 4, with: $0) }
            withUnsafeBytes(of: encoding.littleEndian) { table.replaceSubrange(entry + 4 ..< entry + 8, with: $0) }
            written += 1
        }
        self.filled = 0
    }

    func finish(emit: (Int, UnsafeRawBufferPointer) throws -> Void) throws {
        try flush(emit: emit)
        precondition(written == count, "plain length announced \(plainLength), chunks written \(written) of \(count)")
        try table.withUnsafeBytes { try emit(SnapshotContainer.headerSize, $0) }
    }
}

extension Snapshot {
    /// Produces a compressed file through `writeAt(offset, bytes)`: in order,
    /// except for the chunk table, which is written again at the end at its
    /// place after the header.
    func compressedEncode(writeAt: (Int, UnsafeRawBufferPointer) throws -> Void) throws {
        var writer: ChunkWriter?
        try encode(announcing: { length in
            guard length <= SnapshotContainer.maxPlainLength else {
                throw SnapshotFileError.invalid("too large to compress (\(length) bytes)")
            }
            writer = try ChunkWriter(plainLength: length, emit: writeAt)
        }, { bytes in
            try writer!.add(bytes, emit: writeAt)
        })
        try writer!.finish(emit: writeAt)
    }
}
