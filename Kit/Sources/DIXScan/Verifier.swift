//
//  Verifier.swift
//  DIXScan
//
//  An independent oracle for the scanner. It walks the same tree a different
//  way, with fts(3) and lstat(2) instead of getattrlistbulk, and compares the
//  snapshot with it directory by directory:
//
//  - the exact set of entry names (raw bytes) in every directory
//  - for every non-directory: allocated == st_blocks * 512 and
//    logical == st_size (a hard-link duplicate must have allocated 0 and
//    st_nlink > 1; each (dev, ino) must be owned by exactly one node)
//  - directory vs. file type, symlink flag, and every folder the scanner did
//    not descend has a reason the oracle confirms itself: a different
//    st_dev (mount point), SF_DATALESS (cloud), or a failed read (unreadable)
//
//  fts runs with FTS_PHYSICAL (never follow symlinks) and FTS_XDEV (do not
//  cross devices). It uses chdir(2) internally rather than FTS_NOCHDIR so it
//  can walk trees deeper than PATH_MAX; it restores the working directory.
//
//  GPL v3
//

import Foundation
import DIXCore

public struct VerificationReport: Sendable, CustomStringConvertible {
    /// directories the oracle walked
    public var directoriesChecked = 0
    /// entries the oracle saw
    public var entriesChecked = 0
    /// directories with any difference
    public var mismatchedDirectories = 0
    /// entries missing from either side, or with a wrong type or size
    public var mismatchedEntries = 0
    /// hard-link groups not owned by exactly one node
    public var hardLinkErrors = 0
    /// differences explained by the tree changing after the scan started
    /// (the entry, or its folder, was modified since): not counted as mismatches
    public var changedEntries = 0
    /// the oracle's own total of st_blocks * 512, counting each (dev, ino) once
    public var oracleAllocated: UInt64 = 0
    public var oracleLogical: UInt64 = 0
    /// up to 50 human-readable differences
    public var examples: [String] = []

    public var passed: Bool { mismatchedDirectories == 0 && mismatchedEntries == 0 && hardLinkErrors == 0 }

    public var description: String {
        var s = "oracle: \(directoriesChecked) directories, \(entriesChecked) entries checked; "
        s += "\(mismatchedDirectories) mismatched directories, \(mismatchedEntries) mismatched entries, "
        s += "\(hardLinkErrors) hard-link errors, \(changedEntries) entries changed since the scan; oracle allocated \(oracleAllocated) B, logical \(oracleLogical) B"
        for e in examples { s += "\n  " + e }
        return s
    }
}

public enum Verifier {
    private struct OracleEntry {
        var isDirectory: Bool
        var isSymlink: Bool
        var allocated: UInt64
        var logical: UInt64
        var device: Int32
        var inode: UInt64
        var linkCount: UInt16
        var flags: UInt32
        /// changed (ctime) or created after the scan started
        var changed: Bool
    }

    private struct OracleDirectory {
        var entries: [[UInt8]: OracleEntry] = [:]
        var device: Int32 = 0
        /// fts could not read it
        var unreadable = false
        /// not descended by the oracle (and why)
        var skipped: String?
        /// entries added or removed after the scan started (mtime/ctime)
        var changed = false
    }

    /// Verifies `snapshot` against the tree on disk at `snapshot.rootPath`.
    public static func verify(_ snapshot: Snapshot) -> VerificationReport {
        var report = VerificationReport()
        func note(_ s: String) { if report.examples.count < 50 { report.examples.append(s) } }

        // never download anything while walking
        let savedPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if savedPolicy >= 0 { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, savedPolicy) } }

        // anything modified after this moment changed under the scan
        let scanStart = snapshot.scanDate.timeIntervalSince1970
        func changedSinceScan(_ st: stat) -> Bool {
            func seconds(_ t: timespec) -> Double { Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }
            return seconds(st.st_ctimespec) >= scanStart || seconds(st.st_birthtimespec) >= scanStart
        }

        // MARK: the oracle walk
        var directories: [[UInt8]: OracleDirectory] = [:]
        let rootBytes = Array(snapshot.rootPath.utf8)
        var rootDevice: Int32 = 0
        var seenInodes = Set<[UInt64]>()

        let rootC = strdup(snapshot.rootPath)
        defer { free(rootC) }
        var argv: [UnsafeMutablePointer<CChar>?] = [rootC, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV, nil) else {
            note("fts_open failed: \(String(cString: strerror(errno)))")
            report.mismatchedDirectories = 1
            return report
        }
        defer { fts_close(fts) }

        func bytes(_ p: UnsafeMutablePointer<CChar>, _ length: Int) -> [UInt8] {
            Array(UnsafeRawBufferPointer(start: p, count: length))
        }
        func split(_ path: [UInt8]) -> (parent: [UInt8], name: [UInt8]) {
            guard let slash = path.lastIndex(of: UInt8(ascii: "/")) else { return ([], path) }
            let parent = slash == 0 ? [UInt8(ascii: "/")] : Array(path[..<slash])
            return (parent, Array(path[(slash + 1)...]))
        }

        while let entry = fts_read(fts) {
            let e = entry.pointee
            let path = bytes(e.fts_path, Int(e.fts_pathlen))
            let info = Int32(e.fts_info)
            if info == FTS_DP { continue }      // post-order visit of a directory
            if (info == FTS_DNR || info == FTS_ERR), directories[path] != nil {
                // fts reports a directory it then fails to read a second time
                directories[path]!.unreadable = true
                continue
            }
            var st = stat()
            var haveStat = false
            if let sp = e.fts_statp, info != FTS_NS && info != FTS_NSOK {
                st = sp.pointee
                haveStat = true
            }
            if e.fts_level == 0 {
                rootDevice = st.st_dev
                directories[path, default: OracleDirectory()].device = st.st_dev
                if info == FTS_DNR || info == FTS_ERR { directories[path]!.unreadable = true }
                continue
            }
            let isDirectory = info == FTS_D || info == FTS_DNR || info == FTS_DC
                || (haveStat && st.st_mode & S_IFMT == S_IFDIR)
            let oracle = OracleEntry(
                isDirectory: isDirectory, isSymlink: info == FTS_SL || info == FTS_SLNONE,
                allocated: haveStat && !isDirectory ? UInt64(max(0, st.st_blocks)) * 512 : 0,
                logical: haveStat && !isDirectory ? UInt64(max(0, st.st_size)) : 0,
                device: st.st_dev, inode: st.st_ino, linkCount: st.st_nlink, flags: st.st_flags,
                changed: haveStat && changedSinceScan(st))
            let (parentPath, name) = split(path)
            directories[parentPath, default: OracleDirectory()].entries[name] = oracle
            report.entriesChecked += 1
            if !isDirectory && haveStat {
                if st.st_nlink <= 1 || seenInodes.insert([UInt64(UInt32(bitPattern: st.st_dev)), st.st_ino]).inserted {
                    report.oracleAllocated &+= oracle.allocated
                }
                report.oracleLogical &+= oracle.logical
            }
            if isDirectory {
                var dir = directories[path, default: OracleDirectory()]
                dir.device = st.st_dev
                dir.changed = haveStat && changedSinceScan(st)
                if info == FTS_DNR || info == FTS_ERR {
                    dir.unreadable = true
                } else if st.st_dev != rootDevice && st.st_dev != directories[parentPath]?.device ?? rootDevice {
                    dir.skipped = "mount point"        // FTS_XDEV does not descend it
                } else if st.st_flags & SF_DATALESS_ != 0 {
                    dir.skipped = "cloud"
                    fts_set(fts, entry, FTS_SKIP)
                } else if info == FTS_D, let mount = Self.mountPointCheck(path), mount {
                    dir.skipped = "mount point"
                    fts_set(fts, entry, FTS_SKIP)
                }
                directories[path] = dir
            }
        }

        // MARK: compare, directory by directory
        var ownerCount: [[UInt64]: Int] = [:]
        var linkedNodes: [[UInt64]: Int] = [:]
        var pathOf = [Int: [UInt8]]()
        pathOf[0] = rootBytes
        var queue = [0]
        var visitedPaths = Set<[UInt8]>()
        while let node = queue.popLast() {
            let dirPath = pathOf.removeValue(forKey: node)!
            visitedPaths.insert(dirPath)
            report.directoriesChecked += 1
            let nodeFlags = snapshot.flags[node]
            let oracleDir = directories[dirPath]
            var dirMismatch = false
            defer { if dirMismatch { report.mismatchedDirectories += 1 } }

            let notDescended = nodeFlags.contains(.mountPoint) || nodeFlags.contains(.cloudPlaceholder)
                || (nodeFlags.contains(.unreadable) && snapshot.childCount[node] == 0)
            guard let oracleDir else {
                if !notDescended || node == 0 {
                    note("directory missing from the oracle: \(String(decoding: dirPath, as: UTF8.self))")
                    dirMismatch = true
                }
                continue
            }
            // a folder not descended needs a reason the oracle agrees with
            if nodeFlags.contains(.mountPoint) {
                if oracleDir.skipped != "mount point" {
                    note("flagged mount point, oracle disagrees: \(String(decoding: dirPath, as: UTF8.self))")
                    dirMismatch = true
                }
                continue
            }
            if nodeFlags.contains(.cloudPlaceholder) {
                if oracleDir.skipped != "cloud" {
                    note("flagged cloud folder, oracle disagrees: \(String(decoding: dirPath, as: UTF8.self))")
                    dirMismatch = true
                }
                continue
            }
            if nodeFlags.contains(.unreadable) != oracleDir.unreadable {
                note("unreadable: scanner \(nodeFlags.contains(.unreadable)), oracle \(oracleDir.unreadable): \(String(decoding: dirPath, as: UTF8.self))")
                dirMismatch = true
            }
            if oracleDir.skipped != nil {
                note("oracle skipped (\(oracleDir.skipped!)) but scanner descended: \(String(decoding: dirPath, as: UTF8.self))")
                dirMismatch = true
            }

            var remaining = oracleDir.entries
            for child in snapshot.children(of: node) {
                let start = Int(snapshot.nameOffset[child])
                let name = Array(snapshot.nameBytes[start ..< start + Int(snapshot.nameLength[child])])
                var childPath = dirPath
                if childPath.last != UInt8(ascii: "/") { childPath.append(UInt8(ascii: "/")) }
                childPath.append(contentsOf: name)
                let display = String(decoding: childPath, as: UTF8.self)
                guard let oracle = remaining.removeValue(forKey: name) else {
                    if oracleDir.changed { report.changedEntries += 1; continue }
                    note("only in scan: \(display)")
                    report.mismatchedEntries += 1
                    dirMismatch = true
                    continue
                }
                let f = snapshot.flags[child]
                if f.contains(.directory) != oracle.isDirectory || f.contains(.symlink) != oracle.isSymlink {
                    if oracle.changed { report.changedEntries += 1; continue }
                    note("type differs: \(display)")
                    report.mismatchedEntries += 1
                    dirMismatch = true
                    continue
                }
                if f.contains(.directory) {
                    pathOf[child] = childPath
                    queue.append(child)
                    continue
                }
                let key = [UInt64(UInt32(bitPattern: oracle.device)), oracle.inode]
                var sizeOK = snapshot.logicalSize[child] == oracle.logical
                if f.contains(.hardLinkDuplicate) {
                    sizeOK = sizeOK && snapshot.allocatedSize[child] == 0 && oracle.linkCount > 1
                } else {
                    sizeOK = sizeOK && snapshot.allocatedSize[child] == oracle.allocated
                    if oracle.linkCount > 1 { ownerCount[key, default: 0] += 1 }
                }
                if oracle.linkCount > 1 { linkedNodes[key, default: 0] += 1 }
                if !sizeOK && oracle.changed {
                    report.changedEntries += 1
                } else if !sizeOK {
                    note("size differs: \(display): scan \(snapshot.allocatedSize[child])/\(snapshot.logicalSize[child]), oracle \(oracle.allocated)/\(oracle.logical)")
                    report.mismatchedEntries += 1
                    dirMismatch = true
                }
            }
            for (name, oracle) in remaining {
                if oracle.changed || oracleDir.changed { report.changedEntries += 1; continue }
                var childPath = dirPath
                if childPath.last != UInt8(ascii: "/") { childPath.append(UInt8(ascii: "/")) }
                childPath.append(contentsOf: name)
                note("missing from scan: \(String(decoding: childPath, as: UTF8.self))")
                report.mismatchedEntries += 1
                dirMismatch = true
            }
        }
        for (key, count) in linkedNodes where ownerCount[key, default: 0] != 1 {
            note("hard-link group dev \(key[0]) ino \(key[1]): \(count) links, \(ownerCount[key, default: 0]) owners")
            report.hardLinkErrors += 1
        }
        // directories the oracle walked that the snapshot never reached
        for (path, dir) in directories where !visitedPaths.contains(path) && dir.skipped == nil {
            if !dir.entries.isEmpty || path == rootBytes {
                note("directory not in scan: \(String(decoding: path, as: UTF8.self))")
                report.mismatchedDirectories += 1
            }
        }
        return report
    }

    /// true if `path` is a mount point or automount trigger, per getattrlist
    private static func mountPointCheck(_ path: [UInt8]) -> Bool? {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.dirattr = 0x4      // ATTR_DIR_MOUNTSTATUS
        var buffer = (UInt32(0), UInt32(0))
        let result = (path + [0]).withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) {
                getattrlist($0, &attributes, &buffer, MemoryLayout.size(ofValue: buffer), UInt32(FSOPT_NOFOLLOW))
            }
        }
        guard result == 0 else { return nil }
        return buffer.1 & 0x3 != 0
    }
}
