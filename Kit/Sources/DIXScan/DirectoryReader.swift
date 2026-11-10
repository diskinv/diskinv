//
//  DirectoryReader.swift
//  DIXScan
//
//  Reads one directory with getattrlistbulk(2): every entry's name, type,
//  flags, file ID, link count, sizes, mount status and Finder info in a few
//  system calls per directory, with no per-file objects.
//
//  Completeness rules (each one fixes a way an earlier walker lost files):
//  - getattrlistbulk is called until it returns 0; one call is one batch.
//  - entries are walked by their own length field, and every attribute is
//    read only if the entry's returned-attributes bitmap says it is there.
//  - every object type is recorded: regular files, directories, symlinks,
//    FIFOs, sockets, devices, whiteouts. Only directories are descended.
//  - names are kept as raw bytes, whatever they contain.
//  - an error part-way through a directory keeps the entries already read
//    and marks the directory unreadable.
//  - an entry whose attributes failed (ATTR_CMN_ERROR) is still recorded.
//
//  Sizes: allocated = ATTR_FILE_ALLOCSIZE, the blocks of all forks. On APFS
//  this equals st_blocks * 512, so it agrees with du (including resource
//  forks and decmpfs-compressed files, whose compressed blocks are what is
//  counted). Directories themselves occupy 0 blocks on APFS and are not
//  counted. Small extended attributes stored inline in the inode are counted
//  by neither. logical = ATTR_FILE_DATALENGTH = st_size (for a compressed
//  file, its uncompressed length; for a cloud placeholder, its cloud size).
//
//  GPL v3
//

import Foundation
import DIXCore

// attribute bits (sys/attr.h)
private let ATTR_CMN_NAME_: UInt32 = 0x0000_0001
private let ATTR_CMN_DEVID_: UInt32 = 0x0000_0002
private let ATTR_CMN_OBJTYPE_: UInt32 = 0x0000_0008
private let ATTR_CMN_FNDRINFO_: UInt32 = 0x0000_4000
private let ATTR_CMN_ACCESSMASK_: UInt32 = 0x0002_0000
private let ATTR_CMN_FLAGS_: UInt32 = 0x0004_0000
private let ATTR_CMN_FILEID_: UInt32 = 0x0200_0000
private let ATTR_CMN_ERROR_: UInt32 = 0x2000_0000
private let ATTR_CMN_RETURNED_ATTRS_: UInt32 = 0x8000_0000
private let ATTR_DIR_MOUNTSTATUS_: UInt32 = 0x0000_0004
private let ATTR_FILE_LINKCOUNT_: UInt32 = 0x0000_0001
private let ATTR_FILE_ALLOCSIZE_: UInt32 = 0x0000_0004
private let ATTR_FILE_DATALENGTH_: UInt32 = 0x0000_0200
private let DIR_MNTSTATUS_MNTPOINT_: UInt32 = 0x1
private let DIR_MNTSTATUS_TRIGGER_: UInt32 = 0x2
let SF_DATALESS_: UInt32 = 0x4000_0000
private let kHasBundle_: UInt16 = 0x2000

// vnode types (sys/vnode.h)
private let VREG_: UInt32 = 1, VDIR_: UInt32 = 2, VBLK_: UInt32 = 3, VCHR_: UInt32 = 4
private let VLNK_: UInt32 = 5, VSOCK_: UInt32 = 6, VFIFO_: UInt32 = 7

/// One directory entry as read by a worker (40 bytes). Names live in the
/// directory's own byte buffer.
struct RawEntry {
    var allocated: UInt64
    var logical: UInt64
    var nameOffset: UInt32
    var nameLength: UInt16
    var flags: UInt16          // NodeFlags raw value
    var kindSlot: UInt32       // KindRegistry slot (remapped at assembly)
    var child: Int32           // job id of the directory to descend, or -1
}

/// A hard-linked file seen in a directory. `entry` indexes the entries as
/// read; `nameOffset` identifies the entry after they are sorted.
struct LinkRecord {
    var device: UInt32
    var fileID: UInt64
    var entry: UInt32
    var nameOffset: UInt32
}

/// What a worker learns about one directory.
final class DirResult: @unchecked Sendable {
    let job: Int32
    var entries: [RawEntry] = []
    var names: [UInt8] = []
    var links: [LinkRecord] = []
    /// the directory could not be opened or listed completely
    var unreadable = false
    // filled in at assembly
    var allocatedTotal: UInt64 = 0
    var logicalTotal: UInt64 = 0

    init(job: Int32) { self.job = job }
}

/// A problem met during the scan. Nothing is skipped silently: every folder
/// not descended for an error, and every entry whose attributes could not be
/// read, is reported.
public struct ScanIssue: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// a folder could not be opened (permissions, privacy protection, vanished)
        case unreadableFolder
        /// a folder's listing failed part-way; the entries read so far are kept
        case incompleteFolder
        /// an entry's attributes could not be read; it is recorded with size 0
        case entryError
    }
    public var kind: Kind
    public var path: String
    public var errno: Int32

    public var description: String {
        "\(kind.rawValue): \(path) (\(String(cString: strerror(errno))))"
    }
}

/// Per-worker state: a reusable attribute buffer and a kind cache.
final class DirectoryReader {
    private static let bufferSize = 64 * 1024
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: DirectoryReader.bufferSize, alignment: 16)
    private var attributes = attrlist()
    private var kindCache: [KindKey: (UInt32, Bool)] = [:]
    private let kinds: KindRegistry

    init(kinds: KindRegistry) {
        self.kinds = kinds
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = ATTR_CMN_RETURNED_ATTRS_ | ATTR_CMN_ERROR_ | ATTR_CMN_NAME_ | ATTR_CMN_DEVID_
            | ATTR_CMN_OBJTYPE_ | ATTR_CMN_FNDRINFO_ | ATTR_CMN_ACCESSMASK_ | ATTR_CMN_FLAGS_ | ATTR_CMN_FILEID_
        attributes.dirattr = ATTR_DIR_MOUNTSTATUS_
        attributes.fileattr = ATTR_FILE_LINKCOUNT_ | ATTR_FILE_ALLOCSIZE_ | ATTR_FILE_DATALENGTH_
    }

    deinit { buffer.deallocate() }

    func kindSlot(_ key: KindKey) -> (UInt32, Bool) {
        if let hit = kindCache[key] { return hit }
        let resolved = kinds.slot(for: key)
        kindCache[key] = resolved
        return resolved
    }

    /// Opens a directory without following any symlink on the way. Paths
    /// longer than PATH_MAX are opened one component at a time.
    static func openDirectory(_ path: ContiguousArray<UInt8>) -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        if path.count < Int(PATH_MAX) - 1 {
            var terminated = path
            terminated.append(0)
            return terminated.withUnsafeBufferPointer { p in
                p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) { open($0, (flags & ~O_NOFOLLOW) | 0x2000_0000 /* O_NOFOLLOW_ANY */) }
            }
        }
        // deep path: walk it with openat, closing as we go
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        for component in path.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true) {
            var name = ContiguousArray(component)
            name.append(0)
            let next = name.withUnsafeBufferPointer { p in
                p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) { openat(fd, $0, flags) }
            }
            let saved = errno
            close(fd)
            guard next >= 0 else { errno = saved; return -1 }
            fd = next
        }
        return fd
    }

    /// Opens subdirectory `name` (raw bytes) of the open directory `fd`.
    static func openSubdirectory(_ fd: Int32, _ name: UnsafeRawBufferPointer) -> Int32 {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: name.count + 1) { buffer in
            let raw = UnsafeMutableRawBufferPointer(buffer)
            raw.copyMemory(from: name)
            raw[name.count] = 0
            return openat(fd, buffer.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
    }

    /// Reads directory `job` at `path`, through `fd` if it is already open
    /// (else it is opened by path). Subdirectories to descend are appended to
    /// `subdirectories` as (entry index, path); their RawEntry.child is filled
    /// in by the caller. Returns the open descriptor (or -1); the caller closes it.
    func read(job: Int32, path: ContiguousArray<UInt8>, fd openFD: Int32,
              subdirectories: inout [(entry: Int, path: ContiguousArray<UInt8>)],
              issues: inout [ScanIssue]) -> (DirResult, Int32) {
        let result = DirResult(job: job)
        var fd = openFD >= 0 ? openFD : Self.openDirectory(path)
        // out of descriptors is not "unreadable": wait for other workers to close some
        var waits = 0
        while fd < 0 && (errno == EMFILE || errno == ENFILE || errno == EINTR) && waits < 200 {
            usleep(1000)
            waits += 1
            fd = Self.openDirectory(path)
        }
        if fd < 0 {
            result.unreadable = true
            issues.append(ScanIssue(kind: .unreadableFolder, path: Self.string(path), errno: errno))
            return (result, -1)
        }

        var retries = 0
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, Self.bufferSize, 0)
            if count < 0 {
                let error = errno
                if (error == EINTR || error == EAGAIN) && retries < 100 {
                    retries += 1
                    continue
                }
                result.unreadable = true
                issues.append(ScanIssue(kind: result.entries.isEmpty ? .unreadableFolder : .incompleteFolder,
                                        path: Self.string(path), errno: error))
                break
            }
            if count == 0 { break }
            parse(UnsafeRawBufferPointer(start: buffer, count: Self.bufferSize), count: Int(count), into: result,
                  path: path, subdirectories: &subdirectories, issues: &issues)
        }
        // results live until the end of the scan: drop the slack of array growth
        if result.entries.capacity > result.entries.count {
            result.entries = result.entries.withUnsafeBufferPointer { Array($0) }
        }
        if result.names.capacity > result.names.count + 15 {
            result.names = result.names.withUnsafeBufferPointer { Array($0) }
        }
        return (result, fd)
    }

    /// Parses `count` getattrlistbulk entries from `batch` (internal for tests,
    /// which feed it synthetic batches).
    func parse(_ batch: UnsafeRawBufferPointer, count: Int, into result: DirResult, path: ContiguousArray<UInt8>,
                       subdirectories: inout [(entry: Int, path: ContiguousArray<UInt8>)],
                       issues: inout [ScanIssue]) {
        guard let base = batch.baseAddress else { return }
        let end = base + batch.count
        var entryStart = base
        for _ in 0 ..< count {
            let length = entryStart + 24 <= end ? Int(entryStart.loadUnaligned(as: UInt32.self)) : 0
            guard length >= 24, entryStart + length <= end else {
                // a batch that does not hold the entries it claims: keep what
                // was read and say the folder is incomplete
                result.unreadable = true
                issues.append(ScanIssue(kind: .incompleteFolder, path: Self.string(path), errno: EBADMSG))
                break
            }
            let entryEnd = entryStart + length
            defer { entryStart = entryEnd }

            var field = entryStart + 4
            let common = field.loadUnaligned(as: UInt32.self)
            let dirAttrs = field.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            let fileAttrs = field.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            field += 20

            func take<T>(_ bit: UInt32, in group: UInt32, _ type: T.Type) -> T? {
                guard group & bit != 0, field + MemoryLayout<T>.size <= entryEnd else { return nil }
                let value = field.loadUnaligned(as: T.self)
                field += MemoryLayout<T>.size
                return value
            }

            let entryError = take(ATTR_CMN_ERROR_, in: common, UInt32.self) ?? 0
            // name: attrreference_t { int32 offset (from the reference itself), uint32 length incl. NUL }
            var nameStart = field, nameLength = 0
            if common & ATTR_CMN_NAME_ != 0, field + 8 <= entryEnd {
                let offset = Int(field.loadUnaligned(as: Int32.self))
                let len = Int(field.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                if offset >= 0, len >= 1, field + offset + len <= entryEnd {
                    nameStart = field + offset
                    nameLength = len - 1
                    // the length counts the NUL; be safe if a name holds one early
                    if let nul = UnsafeRawBufferPointer(start: nameStart, count: nameLength).firstIndex(of: 0) {
                        nameLength = nul
                    }
                }
                field += 8
            }
            guard nameLength > 0 else {
                // cannot happen on a sane file system; report rather than drop silently
                issues.append(ScanIssue(kind: .entryError, path: Self.string(path) + "/<entry without a name>", errno: EINVAL))
                continue
            }
            nameLength = min(nameLength, Int(UInt16.max))
            let device = take(ATTR_CMN_DEVID_, in: common, UInt32.self) ?? 0
            let objectType = take(ATTR_CMN_OBJTYPE_, in: common, UInt32.self) ?? 0
            var finderFlags: UInt16 = 0
            if common & ATTR_CMN_FNDRINFO_ != 0, field + 32 <= entryEnd {
                finderFlags = UInt16(bigEndian: field.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
                field += 32
            }
            let accessMask = take(ATTR_CMN_ACCESSMASK_, in: common, UInt32.self) ?? 0
            let bsdFlags = take(ATTR_CMN_FLAGS_, in: common, UInt32.self) ?? 0
            let fileID = take(ATTR_CMN_FILEID_, in: common, UInt64.self) ?? 0
            let mountStatus = take(ATTR_DIR_MOUNTSTATUS_, in: dirAttrs, UInt32.self) ?? 0
            let linkCount = take(ATTR_FILE_LINKCOUNT_, in: fileAttrs, UInt32.self) ?? 1
            let allocated = take(ATTR_FILE_ALLOCSIZE_, in: fileAttrs, Int64.self) ?? 0
            let logical = take(ATTR_FILE_DATALENGTH_, in: fileAttrs, Int64.self) ?? 0

            let name = UnsafeRawBufferPointer(start: nameStart, count: nameLength)
            let nameOffset = UInt32(result.names.count)
            result.names.append(contentsOf: name)

            var flags: NodeFlags = []
            var kind = KindRegistry.folderSlot
            var entry = RawEntry(allocated: 0, logical: 0, nameOffset: nameOffset, nameLength: UInt16(nameLength),
                                 flags: 0, kindSlot: 0, child: -1)
            let entryIndex = result.entries.count

            if entryError != 0 {
                issues.append(ScanIssue(kind: .entryError, path: Self.string(path, appending: name), errno: Int32(bitPattern: entryError)))
            }

            if objectType == VDIR_ {
                flags.insert(.directory)
                var package = finderFlags & kHasBundle_ != 0
                if let key = KindKey.forExtension(of: name, directory: true) {
                    let (slot, isPackage) = kindSlot(key)
                    if isPackage { package = true; kind = slot }
                }
                if package {
                    flags.insert(.package)
                    if kind == KindRegistry.folderSlot { kind = kindSlot(.special(.package)).0 }
                }
                if mountStatus & (DIR_MNTSTATUS_MNTPOINT_ | DIR_MNTSTATUS_TRIGGER_) != 0 {
                    flags.insert(.mountPoint)
                } else if bsdFlags & SF_DATALESS_ != 0 {
                    flags.insert(.cloudPlaceholder)      // listing it would download it
                } else if entryError != 0 {
                    flags.insert(.unreadable)
                } else {
                    subdirectories.append((entryIndex, Self.join(path, name)))
                }
            } else {
                // everything that is not a directory is a file-like leaf
                entry.allocated = allocated > 0 ? UInt64(allocated) : 0
                entry.logical = logical > 0 ? UInt64(logical) : 0
                if bsdFlags & SF_DATALESS_ != 0 { flags.insert(.cloudPlaceholder) }
                switch objectType {
                case VREG_:
                    kind = fileKind(name, executable: accessMask & 0o111 != 0, flags: &flags)
                case VLNK_:
                    flags.insert(.symlink)
                    kind = self.kindSlot(.special(.symlink)).0
                case VFIFO_: kind = self.kindSlot(.special(.fifo)).0
                case VSOCK_: kind = self.kindSlot(.special(.socket)).0
                case VCHR_: kind = self.kindSlot(.special(.characterDevice)).0
                case VBLK_: kind = self.kindSlot(.special(.blockDevice)).0
                default: kind = self.kindSlot(.special(.other)).0
                }
                if linkCount > 1 {
                    result.links.append(LinkRecord(device: device, fileID: fileID, entry: UInt32(entryIndex),
                                                   nameOffset: nameOffset))
                }
            }
            entry.flags = flags.rawValue
            entry.kindSlot = kind
            result.entries.append(entry)
        }
    }

    /// kind of a regular file; also recognizes legacy iCloud stubs ".Name.ext.icloud"
    private func fileKind(_ name: UnsafeRawBufferPointer, executable: Bool, flags: inout NodeFlags) -> UInt32 {
        var name = name
        if Self.isICloudStub(name) {
            flags.insert(.cloudPlaceholder)
            name = UnsafeRawBufferPointer(rebasing: name[1 ..< name.count - 7])
        }
        if let key = KindKey.forExtension(of: name, directory: false) {
            return kindSlot(key).0
        }
        return kindSlot(.special(executable ? .unixExecutable : .document)).0
    }

    static func isICloudStub(_ name: UnsafeRawBufferPointer) -> Bool {
        let suffix = Array(".icloud".utf8)
        guard name.count > suffix.count + 1, name[0] == UInt8(ascii: ".") else { return false }
        return name[(name.count - suffix.count)...].elementsEqual(suffix)
    }

    static func join(_ path: ContiguousArray<UInt8>, _ name: UnsafeRawBufferPointer) -> ContiguousArray<UInt8> {
        var child = ContiguousArray<UInt8>()
        child.reserveCapacity(path.count + 1 + name.count)
        child.append(contentsOf: path)
        if child.last != UInt8(ascii: "/") { child.append(UInt8(ascii: "/")) }
        child.append(contentsOf: name)
        return child
    }

    static func string(_ path: ContiguousArray<UInt8>, appending name: UnsafeRawBufferPointer? = nil) -> String {
        if let name { return String(decoding: join(path, name), as: UTF8.self) }
        return String(decoding: path, as: UTF8.self)
    }
}
