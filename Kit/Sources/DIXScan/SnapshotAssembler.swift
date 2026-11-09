//
//  SnapshotAssembler.swift
//  DIXScan
//
//  Turns the per-directory results of a scan into a Snapshot. Everything that
//  depends on which thread got where first is settled here, deterministically:
//
//  1. hard links: per (device, file ID), the link with the byte-wise smallest
//     path keeps the size; the others get allocated 0 and .hardLinkDuplicate
//  2. sizes: directory totals, bottom-up (a child directory always has a
//     larger job id than its parent, so one pass in descending id order works)
//  3. order: each directory's entries sorted by allocated size descending,
//     then name bytes ascending
//  4. layout: breadth-first, children contiguous
//
//  GPL v3
//

import Foundation
import DIXCore

struct SnapshotAssembler {
    let rootPath: String
    let results: [DirResult]
    let kinds: [FileKind]
    let kindRemap: [UInt16]
    let rootFlags: NodeFlags
    let rootKindSlot: UInt32
    let volume: VolumeInfo?
    let scanDate: Date

    init(rootPath: String, results: [DirResult], kinds: [FileKind], kindRemap: [UInt16],
         rootFlags: NodeFlags, rootKindSlot: UInt32, volume: VolumeInfo?, scanDate: Date) {
        self.rootPath = rootPath
        self.results = results
        self.kinds = kinds
        self.kindRemap = kindRemap
        self.rootFlags = rootFlags
        self.rootKindSlot = rootKindSlot
        self.volume = volume
        self.scanDate = scanDate
    }

    func assemble() throws -> Snapshot {
        resolveHardLinks()
        try computeSizes()
        sortEntries()
        return try layout()
    }

    // MARK: 1. hard links

    /// path of entry `entry` of directory job `job`, as bytes
    private func path(job: Int, entry: Int, parents: [(job: Int32, entry: UInt32)],
                      cache: inout [Int: [UInt8]]) -> [UInt8] {
        func directoryPath(_ job: Int) -> [UInt8] {
            if let hit = cache[job] { return hit }
            // iterative, so a very deep tree cannot exhaust the stack
            var chain: [Int] = []
            var current = job
            while current != 0 && cache[current] == nil {
                chain.append(current)
                current = Int(parents[current].job)
            }
            var bytes = cache[current] ?? Array(rootPath.utf8)
            for link in chain.reversed() {
                let (parentJob, parentEntry) = parents[link]
                appendName(of: Int(parentEntry), in: results[Int(parentJob)], to: &bytes)
            }
            cache[job] = bytes
            return bytes
        }
        var bytes = directoryPath(job)
        appendName(of: entry, in: results[job], to: &bytes)
        return bytes
    }

    private func appendName(of entry: Int, in result: DirResult, to bytes: inout [UInt8]) {
        if bytes.last != UInt8(ascii: "/") { bytes.append(UInt8(ascii: "/")) }
        let e = result.entries[entry]
        bytes.append(contentsOf: result.names[Int(e.nameOffset) ..< Int(e.nameOffset) + Int(e.nameLength)])
    }

    private func resolveHardLinks() {
        struct Link { var device: UInt32; var fileID: UInt64; var job: Int32; var entry: UInt32 }
        var links: [Link] = []
        for result in results {
            for record in result.links {
                links.append(Link(device: record.device, fileID: record.fileID, job: result.job, entry: record.entry))
            }
        }
        guard links.count > 1 else { return }
        links.sort { ($0.device, $0.fileID) < ($1.device, $1.fileID) }

        // parent pointers, only needed to build the paths of linked files
        var parents = [(job: Int32, entry: UInt32)](repeating: (0, 0), count: results.count)
        for result in results {
            for (index, entry) in result.entries.enumerated() where entry.child >= 0 {
                parents[Int(entry.child)] = (result.job, UInt32(index))
            }
        }
        var cache: [Int: [UInt8]] = [:]
        var groupStart = 0
        while groupStart < links.count {
            var groupEnd = groupStart + 1
            while groupEnd < links.count && links[groupEnd].device == links[groupStart].device
                    && links[groupEnd].fileID == links[groupStart].fileID { groupEnd += 1 }
            if groupEnd - groupStart > 1 {
                let members = links[groupStart ..< groupEnd].map { link in
                    (link, path(job: Int(link.job), entry: Int(link.entry), parents: parents, cache: &cache))
                }
                let keeper = members.min { $0.1.lexicographicallyPrecedes($1.1) }!
                for (link, _) in members where !(link.job == keeper.0.job && link.entry == keeper.0.entry) {
                    let result = results[Int(link.job)]
                    result.entries[Int(link.entry)].allocated = 0
                    result.entries[Int(link.entry)].flags |= NodeFlags.hardLinkDuplicate.rawValue
                }
            }
            groupStart = groupEnd
        }
    }

    // MARK: 2. sizes

    private func computeSizes() throws {
        for job in stride(from: results.count - 1, through: 0, by: -1) {
            let result = results[job]
            var allocated: UInt64 = 0, logical: UInt64 = 0
            for index in result.entries.indices {
                let child = result.entries[index].child
                if child >= 0 {
                    let sub = results[Int(child)]
                    result.entries[index].allocated = sub.allocatedTotal
                    result.entries[index].logical = sub.logicalTotal
                    if sub.unreadable { result.entries[index].flags |= NodeFlags.unreadable.rawValue }
                }
                let (a, o1) = allocated.addingReportingOverflow(result.entries[index].allocated)
                let (l, o2) = logical.addingReportingOverflow(result.entries[index].logical)
                if o1 || o2 { throw ScanError.sizeOverflow }
                allocated = a
                logical = l
            }
            result.allocatedTotal = allocated
            result.logicalTotal = logical
        }
    }

    // MARK: 3. order

    private func sortEntries() {
        let results = self.results
        let chunks = max(1, min(results.count, ProcessInfo.processInfo.activeProcessorCount * 4))
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            var job = chunk
            while job < results.count {
                let result = results[job]
                if result.entries.count > 1 {
                    result.names.withUnsafeBufferPointer { names in
                        result.entries.sort { a, b in
                            if a.allocated != b.allocated { return a.allocated > b.allocated }
                            let na = UnsafeBufferPointer(rebasing: names[Int(a.nameOffset) ..< Int(a.nameOffset) + Int(a.nameLength)])
                            let nb = UnsafeBufferPointer(rebasing: names[Int(b.nameOffset) ..< Int(b.nameOffset) + Int(b.nameLength)])
                            return na.lexicographicallyPrecedes(nb)
                        }
                    }
                }
                job += chunks
            }
        }
    }

    // MARK: 4. layout

    private func layout() throws -> Snapshot {
        var total = 1, nameTotal = 0
        for result in results {
            total += result.entries.count
            nameTotal += result.names.count
        }
        let rootName: [UInt8] = rootPath == "/" ? Array("/".utf8) : Array((rootPath as NSString).lastPathComponent.utf8)
        nameTotal += rootName.count
        guard total <= Int(UInt32.max), nameTotal <= Int(UInt32.max) else { throw ScanError.tooManyNodes }

        var parent = [UInt32](repeating: 0, count: total)
        var firstChild = [UInt32](repeating: 0, count: total)
        var childCount = [UInt32](repeating: 0, count: total)
        var allocatedSize = [UInt64](repeating: 0, count: total)
        var logicalSize = [UInt64](repeating: 0, count: total)
        var nameOffset = [UInt32](repeating: 0, count: total)
        var nameLength = [UInt16](repeating: 0, count: total)
        var kindIndex = [UInt16](repeating: 0, count: total)
        var flags = [NodeFlags](repeating: [], count: total)
        var nodeJob = [Int32](repeating: -1, count: total)
        var nameBytes: [UInt8] = []
        nameBytes.reserveCapacity(nameTotal)

        // root
        nameBytes.append(contentsOf: rootName)
        nameLength[0] = UInt16(min(rootName.count, Int(UInt16.max)))
        allocatedSize[0] = results[0].allocatedTotal
        logicalSize[0] = results[0].logicalTotal
        flags[0] = rootFlags
        kindIndex[0] = kindRemap[Int(rootKindSlot)]
        nodeJob[0] = 0

        var next = 1
        for node in 0 ..< total {
            let job = nodeJob[node]
            guard job >= 0 else { continue }
            let result = results[Int(job)]
            firstChild[node] = UInt32(next)
            childCount[node] = UInt32(result.entries.count)
            for entry in result.entries {
                parent[next] = UInt32(node)
                allocatedSize[next] = entry.allocated
                logicalSize[next] = entry.logical
                nameOffset[next] = UInt32(nameBytes.count)
                nameLength[next] = entry.nameLength
                nameBytes.append(contentsOf: result.names[Int(entry.nameOffset) ..< Int(entry.nameOffset) + Int(entry.nameLength)])
                kindIndex[next] = kindRemap[Int(entry.kindSlot)]
                flags[next] = NodeFlags(rawValue: entry.flags)
                nodeJob[next] = entry.child
                next += 1
            }
            // consumed: free it now rather than at the end, to lower the peak
            result.entries = []
            result.names = []
        }
        precondition(next == total)

        return Snapshot(rootPath: rootPath, scanDate: scanDate, volume: volume,
                        parent: parent, firstChild: firstChild, childCount: childCount,
                        allocatedSize: allocatedSize, logicalSize: logicalSize,
                        nameOffset: nameOffset, nameLength: nameLength,
                        kindIndex: kindIndex, flags: flags, nameBytes: nameBytes, kinds: kinds)
    }
}
