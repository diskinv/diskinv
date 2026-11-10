//
//  SnapshotFile.swift
//  DIXCore
//
//  The .dixsnap file format: a Snapshot on disk.
//
//  Binary, little-endian, 8-byte aligned sections:
//
//    offset  size  field
//    0       8     magic "DIXSNAP1"
//    8       4     format version (1)
//    12      4     section count S
//    16      8     node count N
//    24      8     total file length in bytes (detects truncation)
//    32      32    reserved, zero
//    64      24*S  section table: { tag u32, element size u32, offset u64, length u64 }
//    ...           section payloads, each starting at an 8-byte-aligned offset
//
//  Sections (tag = four ASCII bytes read as a little-endian u32):
//    META  root path, scan date (f64 seconds since 2001-01-01, Date's own
//          representation, so it round-trips exactly), volume info
//          (strings are u32 length + UTF-8)
//    KIND  u32 count, then (identifier, name) string pairs
//    PRNT FCHD CCNT NOFF   u32 x N   parent, firstChild, childCount, nameOffset
//    ASIZ LSIZ             u64 x N   allocatedSize, logicalSize
//    NLEN KIDX FLAG        u16 x N   nameLength, kindIndex, flags
//    NAME                  u8  x M   nameBytes (raw bytes, not necessarily UTF-8)
//    HLNK  optional, 16 bytes x L: { node u32, device u32, fileID u64 }, the
//          hard-link table (Snapshot.hardLinks); written only when L > 0, and
//          absent from files written before it existed
//
//  Unknown sections are ignored, so later versions can add data. The loader
//  treats the file as hostile: every count, length and offset is checked
//  against the file size before anything is allocated, and the result must
//  pass Snapshot.validate(). Anything wrong throws SnapshotFileError; nothing
//  traps.
//
//  GPL v3
//

import Foundation

#if !_endian(little)
#error("the .dixsnap reader and writer assume a little-endian host")
#endif

public enum SnapshotFileError: Error, CustomStringConvertible, Equatable {
    case notASnapshot
    case unsupportedVersion(UInt32)
    case malformed(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .notASnapshot: return "not a .dixsnap file"
        case .unsupportedVersion(let v): return "unsupported .dixsnap version \(v)"
        case .malformed(let why): return "malformed .dixsnap file: \(why)"
        case .invalid(let why): return "invalid snapshot in .dixsnap file: \(why)"
        }
    }
}

enum SnapshotFormat {
    static let magic: [UInt8] = Array("DIXSNAP1".utf8)
    static let version: UInt32 = 1
    static let headerSize = 64
    static let tableEntrySize = 24
    /// all NodeFlags bits defined by format version 1
    static let knownFlags: UInt16 = 0x7F

    static func tag(_ s: StaticString) -> UInt32 {
        let p = s.utf8Start
        return UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
    }
    static let meta = tag("META"), kind = tag("KIND"), name = tag("NAME")
    static let prnt = tag("PRNT"), fchd = tag("FCHD"), ccnt = tag("CCNT"), noff = tag("NOFF")
    static let asiz = tag("ASIZ"), lsiz = tag("LSIZ")
    static let nlen = tag("NLEN"), kidx = tag("KIDX"), flag = tag("FLAG")
    static let hlnk = tag("HLNK")
    static let hardLinkRecordSize = 16
}

// MARK: - writing

private struct ByteWriter {
    var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func string(_ s: String) {
        let bytes = Array(s.utf8)
        u32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }
    mutating func array<T: FixedWidthInteger>(_ a: [T]) {
        a.withUnsafeBytes { data.append(contentsOf: $0) }
    }
    mutating func align8() {
        while data.count % 8 != 0 { data.append(0) }
    }
}

/// How a .dixsnap file is stored on disk.
public enum SnapshotFileCompression: Sendable, Hashable {
    /// the plain format (DIXSNAP1): fastest to read, about 7x larger
    case none
    /// LZFSE in independent 4 MiB chunks (DIXSNAPZ, see SnapshotCompression.swift)
    case lzfse
}

public extension Snapshot {
    /// The snapshot encoded as a .dixsnap file (by default uncompressed, so
    /// the bytes are directly comparable).
    func fileData(compression: SnapshotFileCompression = .none) throws -> Data {
        var data = Data()
        switch compression {
        case .none:
            try encode { data.append(contentsOf: $0) }
        case .lzfse:
            try compressedEncode(writeAt: { offset, bytes in
                if offset == data.count {
                    data.append(contentsOf: bytes)
                } else {
                    data.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
                }
            })
        }
        return data
    }

    /// Writes the snapshot as a .dixsnap file, atomically (a temporary file
    /// in the same folder, then rename), compressed with LZFSE unless asked
    /// not to. The arrays are streamed from memory, without building the
    /// whole file in memory first.
    func write(to url: URL, compression: SnapshotFileCompression = .lzfse) throws {
        let path = url.path
        let temporary = path + ".tmp-\(getpid())-\(UInt32.random(in: 0 ... .max))"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary]) }
        var closed = false
        defer {
            if !closed { close(fd) }
            unlink(temporary)       // no-op once renamed
        }
        func writeAll(_ bytes: UnsafeRawBufferPointer, at position: Int?) throws {
            var offset = 0
            while offset < bytes.count {
                let written = position.map { Darwin.pwrite(fd, bytes.baseAddress! + offset, bytes.count - offset, off_t($0 + offset)) }
                    ?? Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
        switch compression {
        case .none:
            try encode { try writeAll($0, at: nil) }
        case .lzfse:
            var end = 0
            try compressedEncode(writeAt: { offset, bytes in
                try writeAll(bytes, at: offset == end ? nil : offset)
                end = max(end, offset + bytes.count)
            })
        }
        guard close(fd) == 0 else { closed = true; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        closed = true
        guard rename(temporary, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Produces the file's bytes in order, as a few large pieces, after
    /// announcing the total length.
    internal func encode(announcing length: (Int) throws -> Void = { _ in },
                         _ sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        if let problem = validate() { throw SnapshotFileError.invalid(problem) }
        guard nodeCount <= Int(UInt32.max), kinds.count <= Int(UInt16.max) + 1 else {
            throw SnapshotFileError.invalid("too many nodes or kinds")
        }
        for s in [rootPath] + kinds.flatMap({ [$0.identifier, $0.name] }) + (volume.map { [$0.name, $0.mountPath] } ?? [])
        where s.utf8.count > Int(UInt32.max) {
            throw SnapshotFileError.invalid("string too long")
        }

        var meta = ByteWriter()
        meta.string(rootPath)
        meta.f64(scanDate.timeIntervalSinceReferenceDate)
        if let volume {
            meta.u8(1)
            meta.string(volume.name)
            meta.string(volume.mountPath)
            meta.u64(volume.totalCapacity)
            meta.u64(volume.availableCapacity)
        } else {
            meta.u8(0)
        }
        var kindTable = ByteWriter()
        kindTable.u32(UInt32(kinds.count))
        for kind in kinds {
            kindTable.string(kind.identifier)
            kindTable.string(kind.name)
        }

        typealias Section = (tag: UInt32, elementSize: UInt32, length: Int,
                             emit: ((UnsafeRawBufferPointer) throws -> Void) throws -> Void)
        func section<T>(_ tag: UInt32, _ array: [T]) -> Section {
            (tag, UInt32(MemoryLayout<T>.stride), array.count * MemoryLayout<T>.stride, { sink in
                try array.withUnsafeBytes { try sink($0) }
            })
        }
        func section(_ tag: UInt32, _ data: Data) -> Section {
            (tag, 1, data.count, { sink in try data.withUnsafeBytes { try sink($0) } })
        }
        // NodeFlags is a UInt16 OptionSet: same layout as its raw value
        let flagBits = flags.map(\.rawValue)
        var sections: [Section] = [
            section(SnapshotFormat.meta, meta.data),
            section(SnapshotFormat.kind, kindTable.data),
            section(SnapshotFormat.prnt, parent),
            section(SnapshotFormat.fchd, firstChild),
            section(SnapshotFormat.ccnt, childCount),
            section(SnapshotFormat.asiz, allocatedSize),
            section(SnapshotFormat.lsiz, logicalSize),
            section(SnapshotFormat.noff, nameOffset),
            section(SnapshotFormat.nlen, nameLength),
            section(SnapshotFormat.kidx, kindIndex),
            section(SnapshotFormat.flag, flagBits),
            section(SnapshotFormat.name, nameBytes),
        ]
        if !hardLinks.isEmpty {
            // HardLink is { u32, u32, u64 }: 16 bytes, no padding, little-endian here
            assert(MemoryLayout<HardLink>.stride == SnapshotFormat.hardLinkRecordSize)
            let links = hardLinks
            sections.append((SnapshotFormat.hlnk, UInt32(SnapshotFormat.hardLinkRecordSize),
                             links.count * SnapshotFormat.hardLinkRecordSize, { sink in
                try links.withUnsafeBytes { try sink($0) }
            }))
        }

        // lay out offsets
        var offsets: [Int] = []
        var cursor = SnapshotFormat.headerSize + SnapshotFormat.tableEntrySize * sections.count
        for s in sections {
            cursor = (cursor + 7) & ~7
            offsets.append(cursor)
            cursor += s.length
        }
        let fileLength = (cursor + 7) & ~7

        var header = ByteWriter()
        header.data.append(contentsOf: SnapshotFormat.magic)
        header.u32(SnapshotFormat.version)
        header.u32(UInt32(sections.count))
        header.u64(UInt64(nodeCount))
        header.u64(UInt64(fileLength))
        header.data.append(contentsOf: [UInt8](repeating: 0, count: 32))
        for (s, offset) in zip(sections, offsets) {
            header.u32(s.tag)
            header.u32(s.elementSize)
            header.u64(UInt64(offset))
            header.u64(UInt64(s.length))
        }
        try length(fileLength)
        var position = header.data.count
        try header.data.withUnsafeBytes { try sink($0) }
        let zeros = [UInt8](repeating: 0, count: 8)
        func pad(to target: Int) throws {
            precondition(target >= position && target - position < 8)
            if target > position { try zeros.withUnsafeBytes { try sink(UnsafeRawBufferPointer(rebasing: $0[0 ..< target - position])) } }
            position = target
        }
        for (s, offset) in zip(sections, offsets) {
            try pad(to: offset)
            try s.emit(sink)
            position += s.length
        }
        try pad(to: fileLength)
    }

    /// Reads a .dixsnap file, compressed or not. Throws on anything
    /// malformed; never traps.
    init(contentsOf url: URL) throws {
        // Read, not map: a mapped file truncated by someone else while we
        // parse it would fault.
        let data = try Data(contentsOf: url)
        try self.init(fileData: data)
    }

    /// Decodes a .dixsnap file's bytes, compressed or not. Throws on anything
    /// malformed; never traps.
    init(fileData data: Data) throws {
        self = try data.withUnsafeBytes { raw in
            if SnapshotContainer.isCompressed(raw) {
                let plain = try SnapshotContainer.decompress(raw)
                return try plain.withUnsafeBytes { try SnapshotDecoder($0).decode() }
            }
            return try SnapshotDecoder(raw).decode()
        }
    }
}

// MARK: - reading

private struct ByteReader {
    let bytes: UnsafeRawBufferPointer
    var position: Int
    let end: Int

    init(_ bytes: UnsafeRawBufferPointer, from start: Int, length: Int) {
        self.bytes = bytes
        self.position = start
        self.end = start + length
    }

    var remaining: Int { end - position }

    mutating func take(_ count: Int) throws -> UnsafeRawBufferPointer {
        guard count >= 0, count <= remaining else { throw SnapshotFileError.malformed("unexpected end of data") }
        let slice = UnsafeRawBufferPointer(rebasing: bytes[position ..< position + count])
        position += count
        return slice
    }
    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func u32() throws -> UInt32 { UInt32(littleEndian: try take(4).loadUnaligned(as: UInt32.self)) }
    mutating func u64() throws -> UInt64 { UInt64(littleEndian: try take(8).loadUnaligned(as: UInt64.self)) }
    mutating func string() throws -> String {
        let length = try u32()
        guard Int(length) <= remaining else { throw SnapshotFileError.malformed("string longer than its section") }
        return String(decoding: try take(Int(length)), as: UTF8.self)
    }
}

private struct SnapshotDecoder {
    let raw: UnsafeRawBufferPointer
    init(_ raw: UnsafeRawBufferPointer) { self.raw = raw }

    struct SectionEntry { var elementSize: UInt32; var offset: Int; var length: Int }

    func decode() throws -> Snapshot {
        guard raw.count >= SnapshotFormat.headerSize,
              raw.prefix(8).elementsEqual(SnapshotFormat.magic) else { throw SnapshotFileError.notASnapshot }
        var header = ByteReader(raw, from: 8, length: SnapshotFormat.headerSize - 8)
        let version = try header.u32()
        guard version == SnapshotFormat.version else { throw SnapshotFileError.unsupportedVersion(version) }
        let sectionCount = try header.u32()
        let nodeCount64 = try header.u64()
        let fileLength = try header.u64()
        guard fileLength == UInt64(raw.count) else {
            throw SnapshotFileError.malformed("file is \(raw.count) bytes, header says \(fileLength)")
        }
        // every node needs at least 38 bytes of arrays, so the file size caps the count
        guard nodeCount64 >= 1, nodeCount64 <= UInt64(UInt32.max), nodeCount64 <= UInt64(raw.count / 38) else {
            throw SnapshotFileError.malformed("node count \(nodeCount64) impossible for the file size")
        }
        let n = Int(nodeCount64)
        guard sectionCount <= 1024,
              Int(sectionCount) * SnapshotFormat.tableEntrySize <= raw.count - SnapshotFormat.headerSize else {
            throw SnapshotFileError.malformed("section table out of bounds")
        }

        var table = ByteReader(raw, from: SnapshotFormat.headerSize,
                               length: Int(sectionCount) * SnapshotFormat.tableEntrySize)
        var sections: [UInt32: SectionEntry] = [:]
        for _ in 0 ..< sectionCount {
            let tag = try table.u32(), elementSize = try table.u32()
            let offset = try table.u64(), length = try table.u64()
            guard offset <= UInt64(raw.count), length <= UInt64(raw.count) - offset else {
                throw SnapshotFileError.malformed("section out of bounds")
            }
            guard sections[tag] == nil else { throw SnapshotFileError.malformed("duplicate section") }
            sections[tag] = SectionEntry(elementSize: elementSize, offset: Int(offset), length: Int(length))
        }

        func section(_ tag: UInt32) throws -> SectionEntry {
            guard let s = sections[tag] else { throw SnapshotFileError.malformed("missing section") }
            return s
        }
        func array<T: FixedWidthInteger>(_ tag: UInt32, count: Int? = nil, as: T.Type) throws -> [T] {
            let s = try section(tag)
            let size = MemoryLayout<T>.size
            guard s.elementSize == UInt32(size) else { throw SnapshotFileError.malformed("bad element size") }
            let expected = count ?? (s.length / size)
            guard s.length % size == 0, s.length / size == expected else {
                throw SnapshotFileError.malformed("section length does not match node count")
            }
            let source = UnsafeRawBufferPointer(rebasing: raw[s.offset ..< s.offset + s.length])
            return [T](unsafeUninitializedCapacity: expected) { buffer, initialized in
                if expected > 0 {
                    UnsafeMutableRawBufferPointer(buffer).copyMemory(from: source)
                }
                initialized = expected
            }
        }

        // META
        let metaEntry = try section(SnapshotFormat.meta)
        guard metaEntry.elementSize == 1 else { throw SnapshotFileError.malformed("bad element size") }
        var meta = ByteReader(raw, from: metaEntry.offset, length: metaEntry.length)
        let rootPath = try meta.string()
        let interval = Double(bitPattern: try meta.u64())
        guard interval.isFinite, abs(interval) < 1e11 else { throw SnapshotFileError.malformed("bad scan date") }
        var volume: VolumeInfo?
        switch try meta.u8() {
        case 0: volume = nil
        case 1:
            let name = try meta.string(), mountPath = try meta.string()
            let total = try meta.u64(), available = try meta.u64()
            volume = VolumeInfo(name: name, mountPath: mountPath, totalCapacity: total, availableCapacity: available)
        default: throw SnapshotFileError.malformed("bad volume marker")
        }

        // KIND
        let kindEntry = try section(SnapshotFormat.kind)
        guard kindEntry.elementSize == 1 else { throw SnapshotFileError.malformed("bad element size") }
        var kindReader = ByteReader(raw, from: kindEntry.offset, length: kindEntry.length)
        let kindCount = try kindReader.u32()
        // each kind takes at least 8 bytes, which caps the count
        guard kindCount >= 1, kindCount <= UInt32(UInt16.max) + 1, Int(kindCount) <= kindReader.remaining / 8 else {
            throw SnapshotFileError.malformed("bad kind count")
        }
        var kinds: [FileKind] = []
        kinds.reserveCapacity(Int(kindCount))
        for _ in 0 ..< kindCount {
            let identifier = try kindReader.string(), name = try kindReader.string()
            kinds.append(FileKind(identifier: identifier, name: name))
        }

        // HLNK (optional): node u32, device u32, fileID u64; validate() checks the rest
        var hardLinks: [HardLink] = []
        if let s = sections[SnapshotFormat.hlnk] {
            let size = SnapshotFormat.hardLinkRecordSize
            guard s.elementSize == UInt32(size), s.length % size == 0, s.length / size <= n else {
                throw SnapshotFileError.malformed("bad hard-link table")
            }
            var reader = ByteReader(raw, from: s.offset, length: s.length)
            hardLinks.reserveCapacity(s.length / size)
            for _ in 0 ..< s.length / size {
                let node = try reader.u32(), device = try reader.u32(), fileID = try reader.u64()
                hardLinks.append(HardLink(node: node, device: device, fileID: fileID))
            }
        }

        let flagBits = try array(SnapshotFormat.flag, count: n, as: UInt16.self)
        guard flagBits.allSatisfy({ $0 & ~SnapshotFormat.knownFlags == 0 }) else {
            throw SnapshotFileError.malformed("unknown node flags")
        }
        let snapshot = Snapshot(
            rootPath: rootPath,
            scanDate: Date(timeIntervalSinceReferenceDate: interval),
            volume: volume,
            parent: try array(SnapshotFormat.prnt, count: n, as: UInt32.self),
            firstChild: try array(SnapshotFormat.fchd, count: n, as: UInt32.self),
            childCount: try array(SnapshotFormat.ccnt, count: n, as: UInt32.self),
            allocatedSize: try array(SnapshotFormat.asiz, count: n, as: UInt64.self),
            logicalSize: try array(SnapshotFormat.lsiz, count: n, as: UInt64.self),
            nameOffset: try array(SnapshotFormat.noff, count: n, as: UInt32.self),
            nameLength: try array(SnapshotFormat.nlen, count: n, as: UInt16.self),
            kindIndex: try array(SnapshotFormat.kidx, count: n, as: UInt16.self),
            flags: flagBits.map { NodeFlags(rawValue: $0) },
            nameBytes: try array(SnapshotFormat.name, as: UInt8.self),
            kinds: kinds,
            hardLinks: hardLinks)
        if let problem = snapshot.validate() { throw SnapshotFileError.invalid(problem) }
        return snapshot
    }
}

// MARK: - summary

/// What a snapshot holds and, as important, what it could not look into.
/// Computed from the node flags, so it is the same for a live scan and for a
/// snapshot loaded from a file.
public struct SnapshotSummary: Sendable, Hashable {
    public var files = 0
    public var directories = 0
    public var packages = 0
    public var symlinks = 0
    /// cloud placeholder files (data not on this disk)
    public var cloudFiles = 0
    /// cloud placeholder folders, not descended (that would download them)
    public var cloudFolders = 0
    public var hardLinkDuplicates = 0
    /// folders with another volume mounted on them, not descended
    public var mountPoints = 0
    /// folders that could not be read (permissions, privacy protection)
    public var unreadableFolders = 0
    public var allocatedSize: UInt64 = 0
    public var logicalSize: UInt64 = 0

    /// number of folders whose contents are missing from the snapshot
    public var foldersNotDescended: Int { cloudFolders + mountPoints + unreadableFolders }
}

public extension Snapshot {
    var summary: SnapshotSummary {
        var s = SnapshotSummary()
        s.allocatedSize = allocatedSize.first ?? 0
        s.logicalSize = logicalSize.first ?? 0
        for f in flags {
            if f.contains(.directory) {
                s.directories += 1
                if f.contains(.package) { s.packages += 1 }
                if f.contains(.cloudPlaceholder) { s.cloudFolders += 1 }
                if f.contains(.mountPoint) { s.mountPoints += 1 }
                if f.contains(.unreadable) { s.unreadableFolders += 1 }
            } else {
                s.files += 1
                if f.contains(.symlink) { s.symlinks += 1 }
                if f.contains(.cloudPlaceholder) { s.cloudFiles += 1 }
                if f.contains(.hardLinkDuplicate) { s.hardLinkDuplicates += 1 }
            }
        }
        return s
    }
}
