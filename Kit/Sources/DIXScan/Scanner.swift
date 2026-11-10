//
//  Scanner.swift
//  DIXScan
//
//  Scans a folder into a Snapshot.
//
//  Workers pull directories from a shared stack, read each with
//  getattrlistbulk (DirectoryReader), and push its subdirectories. The only
//  shared state is that stack and its counters, taken once per directory, and
//  the kind registry, taken only when a worker meets an extension it has not
//  seen. Nothing shared is touched per file. After the walk, everything
//  order-dependent is settled deterministically: hard-link ownership
//  (smallest path), the kind table (sorted), and the node layout (BFS,
//  children sorted by size then name).
//
//  The scan never follows symlinks, never descends mount points or cloud
//  placeholder folders, and never materializes dataless files: each worker
//  thread sets IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES to OFF.
//
//  GPL v3
//

import Foundation
import DIXCore

public enum ScanError: Error, CustomStringConvertible {
    case cannotOpenRoot(path: String, errno: Int32)
    case notADirectory(String)
    case cancelled
    case tooManyNodes
    case sizeOverflow

    public var description: String {
        switch self {
        case .cannotOpenRoot(let path, let e): return "cannot open \(path): \(String(cString: strerror(e)))"
        case .notADirectory(let path): return "\(path) is not a folder"
        case .cancelled: return "scan cancelled"
        case .tooManyNodes: return "too many items for one snapshot"
        case .sizeOverflow: return "sizes overflow 64 bits"
        }
    }
}

/// Live counters, readable from any thread while a scan runs.
public struct ScanProgress: Sendable {
    /// entries found so far (files and folders, not counting the root)
    public var items: Int
    public var directoriesRead: Int
    public var allocatedBytes: UInt64
    public var logicalBytes: UInt64
    /// the folder most recently read
    public var currentPath: String
    /// how many items the scan will find, when knowable (volume roots): the
    /// volume's used inode count. A progress bar can show items / expected.
    public var expectedItemCount: Int?
    public var isFinished: Bool
}

/// The scan's result: the snapshot plus everything that went wrong.
public struct ScanResult: Sendable {
    public var snapshot: Snapshot
    /// counts by flag, including folders not descended and why
    public var summary: SnapshotSummary
    /// problems, sorted by path (at most `Scanner.Options.maxIssues` kept)
    public var issues: [ScanIssue]
    /// total number of problems, including any not kept in `issues`
    public var issueCount: Int
    /// entries whose attributes could not be read (recorded with size 0)
    public var entryErrors: Int
    public var duration: TimeInterval
    /// of which: reading directories (the rest is assembling the snapshot)
    public var walkDuration: TimeInterval
    /// distinct extensions resolved through LaunchServices
    public var kindLookups: Int
}

public final class Scanner: @unchecked Sendable {
    public struct Options: Sendable {
        /// worker threads; default: all active processors. Capping it at 8
        /// was measured and is slower (15-core machine, 5 P + 10 E cores,
        /// warm cache, median of 8 runs): ~/b 0.725 s at 8 vs 0.668 s at 15,
        /// /Applications 1.646 vs 1.489 s, /System/Library 1.685 vs 1.650 s.
        public var workerCount: Int
        /// how many issues to keep (all are counted)
        public var maxIssues: Int
        /// also set the no-materialize policy for the whole process (the
        /// worker threads always have it)
        public var setProcessMaterializationPolicy: Bool

        public init(workerCount: Int = ProcessInfo.processInfo.activeProcessorCount,
                    maxIssues: Int = 10_000, setProcessMaterializationPolicy: Bool = false) {
            self.workerCount = max(1, workerCount)
            self.maxIssues = maxIssues
            self.setProcessMaterializationPolicy = setProcessMaterializationPolicy
        }
    }

    public let rootPath: String
    public let options: Options

    // shared state, all guarded by `condition`
    /// a directory to read; `fd` is the directory already opened relative to
    /// its parent (cheaper for the kernel than resolving the whole path), or -1
    private struct Job { var id: Int32; var path: ContiguousArray<UInt8>; var fd: Int32 }
    private let condition = NSCondition()
    private var stack: [Job] = []
    private var pending = 0
    private var nextJobID = 0
    private var cancelled = false
    private var overflowed = false
    private var finished = false
    private var items = 0
    private var directoriesRead = 0
    private var allocatedBytes: UInt64 = 0
    private var logicalBytes: UInt64 = 0
    private var currentPath = ContiguousArray<UInt8>()
    private var expected: Int?
    /// descriptors held by queued jobs, and how many they may hold
    private var openDescriptors = 0
    private var descriptorBudget = 0

    /// `path` is resolved (realpath) first, so the root may be given through
    /// a symlink; nothing below it is followed.
    public init(path: String, options: Options = Options()) {
        self.rootPath = path
        self.options = options
    }

    public var progress: ScanProgress {
        condition.lock()
        defer { condition.unlock() }
        return ScanProgress(items: items, directoriesRead: directoriesRead, allocatedBytes: allocatedBytes,
                            logicalBytes: logicalBytes, currentPath: String(decoding: currentPath, as: UTF8.self),
                            expectedItemCount: expected, isFinished: finished)
    }

    /// Stops a running scan; `scan()` then throws `ScanError.cancelled`.
    public func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    private static func mountInfo(_ path: String) -> (usedInodes: Int, mountPath: String, fs: statfs)? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let mount = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let used = fs.f_files >= fs.f_ffree ? Int(fs.f_files - fs.f_ffree) : 0
        return (used, mount, fs)
    }

    /// Item count to expect when scanning `path`: the used inode count if it
    /// is a volume root (for "/", plus the Data volume's), else nil.
    public static func expectedItemCount(forRoot path: String) -> Int? {
        guard let info = mountInfo(path), info.mountPath == path else { return nil }
        if path == "/", let data = mountInfo("/System/Volumes/Data"), data.mountPath == "/System/Volumes/Data" {
            return info.usedInodes + data.usedInodes
        }
        return info.usedInodes
    }

    static func volumeInfo(for path: String) -> VolumeInfo? {
        guard let info = mountInfo(path) else { return nil }
        let name = (try? URL(fileURLWithPath: info.mountPath).resourceValues(forKeys: [.volumeNameKey]).volumeName)
            ?? (info.mountPath as NSString).lastPathComponent
        let blockSize = UInt64(info.fs.f_bsize)
        return VolumeInfo(name: name, mountPath: info.mountPath,
                          totalCapacity: info.fs.f_blocks &* blockSize,
                          availableCapacity: info.fs.f_bavail &* blockSize)
    }

    // MARK: scanning

    /// Scans synchronously on worker threads; call it off the main thread.
    /// A Scanner scans once.
    public func scan() throws -> ScanResult {
        let start = Date()
        if options.setProcessMaterializationPolicy {
            _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        }
        // the root: resolve it and check it is a directory
        guard let resolved = realpath(rootPath, nil) else {
            throw ScanError.cannotOpenRoot(path: rootPath, errno: errno)
        }
        let root = String(cString: resolved)
        free(resolved)
        var st = stat()
        guard lstat(root, &st) == 0 else { throw ScanError.cannotOpenRoot(path: root, errno: errno) }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw ScanError.notADirectory(root) }

        let kinds = KindRegistry()

        condition.lock()
        stack = [Job(id: 0, path: ContiguousArray(root.utf8), fd: -1)]
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        descriptorBudget = max(0, min(Int(limit.rlim_cur) / 2, 4096) - 2 * options.workerCount - 16)
        pending = 1
        nextJobID = 1
        expected = Self.expectedItemCount(forRoot: root)
        condition.unlock()

        final class WorkerOutput: @unchecked Sendable {
            var results: [DirResult] = []
            var issues: [ScanIssue] = []
        }
        let outputs = (0 ..< options.workerCount).map { _ in WorkerOutput() }
        let group = DispatchGroup()
        for output in outputs {
            group.enter()
            let thread = Thread { [self] in
                _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                                   IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
                let reader = DirectoryReader(kinds: kinds)
                self.work(reader: reader, results: &output.results, issues: &output.issues)
                group.leave()
            }
            thread.stackSize = 1 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()
        let walkDuration = Date().timeIntervalSince(start)

        condition.lock()
        let wasCancelled = cancelled, didOverflow = overflowed
        let jobCount = nextJobID
        condition.unlock()
        for job in stack where job.fd >= 0 { close(job.fd) }     // left over after a cancel
        stack.removeAll()
        if didOverflow { throw ScanError.tooManyNodes }
        if wasCancelled { throw ScanError.cancelled }

        var slots = [DirResult?](repeating: nil, count: jobCount)
        var issues: [ScanIssue] = []
        for output in outputs {
            for result in output.results { slots[Int(result.job)] = result }
            issues.append(contentsOf: output.issues)
        }
        // every pushed job was processed, since the scan was not cancelled
        let results = slots.map { $0! }

        let (kindTable, remap) = kinds.finalTable()
        let (rootFlags, rootKind) = Self.rootFlags(root: root, kinds: kinds, unreadable: results[0].unreadable)
        let snapshot = try SnapshotAssembler(
            rootPath: root, results: results, kinds: kindTable, kindRemap: remap,
            rootFlags: rootFlags, rootKindSlot: rootKind,
            volume: Self.volumeInfo(for: root), scanDate: start).assemble()

        condition.lock()
        finished = true
        condition.unlock()

        issues.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        let issueCount = issues.count
        let entryErrors = issues.filter { $0.kind == .entryError }.count
        if issues.count > options.maxIssues { issues.removeSubrange(options.maxIssues...) }
        return ScanResult(snapshot: snapshot, summary: snapshot.summary, issues: issues, issueCount: issueCount,
                          entryErrors: entryErrors, duration: Date().timeIntervalSince(start), walkDuration: walkDuration,
                          kindLookups: kinds.lookups)
    }

    private static func rootFlags(root: String, kinds: KindRegistry, unreadable: Bool) -> (NodeFlags, UInt32) {
        var flags: NodeFlags = .directory
        var kind = KindRegistry.folderSlot
        let name = Array((root as NSString).lastPathComponent.utf8)
        name.withUnsafeBytes { bytes in
            if let key = KindKey.forExtension(of: bytes, directory: true) {
                let (slot, package) = kinds.slot(for: key)
                if package { kind = slot; flags.insert(.package) }
            }
        }
        if unreadable { flags.insert(.unreadable) }
        return (flags, kind)
    }

    private func work(reader: DirectoryReader, results: inout [DirResult], issues: inout [ScanIssue]) {
        var subdirectories: [(entry: Int, path: ContiguousArray<UInt8>)] = []
        while true {
            condition.lock()
            while stack.isEmpty && pending > 0 && !cancelled { condition.wait() }
            if cancelled || stack.isEmpty {
                condition.unlock()
                return
            }
            let job = stack.removeLast()
            condition.unlock()

            subdirectories.removeAll(keepingCapacity: true)
            let (result, fd) = reader.read(job: job.id, path: job.path, fd: job.fd,
                                           subdirectories: &subdirectories, issues: &issues)
            // open subdirectories relative to this one while it is open, as far
            // as the descriptor budget allows
            var childFDs: [Int32] = []
            if fd >= 0 && !subdirectories.isEmpty {
                condition.lock()
                let grant = max(0, min(subdirectories.count, descriptorBudget - openDescriptors))
                openDescriptors += grant
                condition.unlock()
                childFDs.reserveCapacity(grant)
                for (entry, _) in subdirectories.prefix(grant) {
                    let e = result.entries[entry]
                    let child = result.names.withUnsafeBytes {
                        DirectoryReader.openSubdirectory(fd, UnsafeRawBufferPointer(rebasing: $0[Int(e.nameOffset) ..< Int(e.nameOffset) + Int(e.nameLength)]))
                    }
                    childFDs.append(child)
                }
                let failed = childFDs.filter { $0 < 0 }.count
                if failed > 0 {
                    condition.lock()
                    openDescriptors -= failed
                    condition.unlock()
                }
            }
            if fd >= 0 { close(fd) }
            if job.fd >= 0 {
                condition.lock()
                openDescriptors -= 1
                condition.unlock()
            }
            var allocated: UInt64 = 0, logical: UInt64 = 0
            for entry in result.entries {
                allocated &+= entry.allocated
                logical &+= entry.logical
            }

            condition.lock()
            for (index, (entry, path)) in subdirectories.enumerated() {
                guard nextJobID < Int(Int32.max) else { overflowed = true; cancelled = true; break }
                result.entries[entry].child = Int32(nextJobID)
                stack.append(Job(id: Int32(nextJobID), path: path, fd: index < childFDs.count ? childFDs[index] : -1))
                nextJobID += 1
                pending += 1
            }
            pending -= 1
            items += result.entries.count
            directoriesRead += 1
            allocatedBytes &+= allocated
            logicalBytes &+= logical
            currentPath = job.path
            if pending == 0 || cancelled || subdirectories.count > 1 {
                condition.broadcast()
            } else if subdirectories.count == 1 {
                condition.signal()
            }
            condition.unlock()
            results.append(result)
        }
    }
}
