//
//  dix-scan: scan a folder into a .dixsnap file, inspect one, or check a
//  scan against an independent walk.
//
//    dix-scan <folder> [-o out.dixsnap] [--uncompressed] [--workers N] [--reproducible]
//             [--verify] [--issues] [--progress] [--quiet]
//    dix-scan --info <file.dixsnap>
//    dix-scan --dump <file.dixsnap> [--depth N]
//    dix-scan --export tsv <file.dixsnap> -o out.tsv
//    dix-scan --convert <file.dixsnap> -o out.dixsnap [--uncompressed]
//    dix-scan --bench-edit <file.dixsnap>
//
//  .dixsnap files are written LZFSE-compressed unless --uncompressed; both
//  kinds are read everywhere.
//
//  --reproducible  write scan date 0 and no volume info (free space changes
//                  between runs), so two scans of an unchanged tree give
//                  byte-identical files
//  --verify        after scanning, walk the tree again with fts(3)/lstat(2)
//                  and compare every directory's entries and every file's sizes
//
//  GPL v3
//

import Foundation
import DIXCore
import DIXScan

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func formatBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes), unit = 0
    while value >= 1000 && unit < units.count - 1 { value /= 1000; unit += 1 }
    return unit == 0 ? "\(bytes) B" : String(format: "%.2f %@", value, units[unit])
}

func peakRSS() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return UInt64(usage.ru_maxrss)      // bytes on macOS
}

func printSummary(_ snapshot: Snapshot) {
    let s = snapshot.summary
    print("root:        \(snapshot.rootPath)")
    print("nodes:       \(snapshot.nodeCount) (\(s.files) files, \(s.directories) folders, \(s.packages) packages, \(s.symlinks) symlinks)")
    print("allocated:   \(s.allocatedSize) B (\(formatBytes(s.allocatedSize)), \(s.allocatedSize / 1024) KiB)")
    print("logical:     \(s.logicalSize) B (\(formatBytes(s.logicalSize)))")
    print("kinds:       \(snapshot.kinds.count)")
    print("hard links:  \(s.hardLinkDuplicates) duplicate links counted once")
    print("cloud:       \(s.cloudFiles) placeholder files, \(s.cloudFolders) placeholder folders (not downloaded)")
    print("not read:    \(s.foldersNotDescended) folders not descended: \(s.unreadableFolders) unreadable, \(s.mountPoints) mount points, \(s.cloudFolders) cloud")
    if let v = snapshot.volume {
        print("volume:      \(v.name) at \(v.mountPath), \(formatBytes(v.totalCapacity)) total, \(formatBytes(v.availableCapacity)) free")
    }
}

func runCLI() {
    var arguments = Array(CommandLine.arguments.dropFirst())
    func takeFlag(_ name: String) -> Bool {
        if let i = arguments.firstIndex(of: name) { arguments.remove(at: i); return true }
        return false
    }
    func takeValue(_ names: String...) -> String? {
        for name in names {
            if let i = arguments.firstIndex(of: name) {
                guard i + 1 < arguments.count else { fail("\(name) needs a value") }
                let value = arguments[i + 1]
                arguments.removeSubrange(i ... i + 1)
                return value
            }
        }
        return nil
    }

    if takeFlag("-h") || takeFlag("--help") || arguments.isEmpty {
        print("""
        usage: dix-scan <folder> [-o out.dixsnap] [--uncompressed] [--workers N] [--reproducible] [--verify] [--issues] [--progress] [--quiet]
               dix-scan --info <file.dixsnap>
               dix-scan --dump <file.dixsnap> [--depth N]
               dix-scan --export tsv <file.dixsnap> -o out.tsv
               dix-scan --convert <file.dixsnap> -o out.dixsnap [--uncompressed]
               dix-scan --bench-edit <file.dixsnap>
        """)
        exit(arguments.isEmpty ? 1 : 0)
    }

    // MARK: --info / --dump / --bench-edit

    let compression: SnapshotFileCompression = takeFlag("--uncompressed") ? .none : .lzfse

    if let file = takeValue("--convert") {
        guard let output = takeValue("-o", "--output") else { fail("--convert needs -o out.dixsnap") }
        let t0 = Date()
        let snapshot: Snapshot
        do { snapshot = try Snapshot(contentsOf: URL(fileURLWithPath: file)) } catch { fail("\(file): \(error)") }
        let t1 = Date()
        do { try snapshot.write(to: URL(fileURLWithPath: output), compression: compression) } catch { fail("cannot write \(output): \(error)") }
        let size = (try? FileManager.default.attributesOfItem(atPath: output)[.size] as? Int) ?? 0
        print(String(format: "%@ -> %@ (%@, %d bytes): read %.1f ms, wrote %.1f ms", file, output,
                     compression == .none ? "uncompressed" : "lzfse", size,
                     t1.timeIntervalSince(t0) * 1000, Date().timeIntervalSince(t1) * 1000))
        exit(0)
    }

    if let format = takeValue("--export") {
        guard format == "tsv" else { fail("--export: only tsv is supported") }
        guard let output = takeValue("-o", "--output"), arguments.count == 1 else {
            fail("usage: dix-scan --export tsv <file.dixsnap> -o out.tsv")
        }
        let file = arguments[0]
        let snapshot: Snapshot
        do { snapshot = try Snapshot(contentsOf: URL(fileURLWithPath: file)) } catch { fail("\(file): \(error)") }
        let t0 = Date()
        do { try exportTSV(snapshot, to: output) } catch { fail("cannot write \(output): \(error)") }
        print(String(format: "exported %d rows to %@ in %.2f s", snapshot.nodeCount, output, Date().timeIntervalSince(t0)))
        exit(0)
    }

    if let file = takeValue("--bench-edit") {
        let snapshot: Snapshot
        do { snapshot = try Snapshot(contentsOf: URL(fileURLWithPath: file)) } catch { fail("\(file): \(error)") }
        benchEdits(snapshot)
        exit(0)
    }

    if let file = takeValue("--info") {
        let t0 = Date()
        let snapshot: Snapshot
        do { snapshot = try Snapshot(contentsOf: URL(fileURLWithPath: file)) } catch { fail("\(file): \(error)") }
        let loadTime = Date().timeIntervalSince(t0)
        printSummary(snapshot)
        print(String(format: "loaded in:   %.1f ms (including validate)", loadTime * 1000))
        print("scan date:   \(snapshot.scanDate)")
        exit(0)
    }

    if let file = takeValue("--dump") {
        let depthLimit = takeValue("--depth").flatMap(Int.init) ?? Int.max
        let snapshot: Snapshot
        do { snapshot = try Snapshot(contentsOf: URL(fileURLWithPath: file)) } catch { fail("\(file): \(error)") }
        var out = ""
        var stack: [(Int, Int)] = [(0, 0)]
        while let (node, depth) = stack.popLast() {
            out += "\(flagString(snapshot.flags[node]))\t\(snapshot.allocatedSize[node])\t\(snapshot.logicalSize[node])\t\(snapshot.kind(of: node).name)\t\(snapshot.path(of: node))\n"
            if out.utf8.count > 1 << 20 { FileHandle.standardOutput.write(Data(out.utf8)); out = "" }
            if depth < depthLimit {
                for child in snapshot.children(of: node).reversed() { stack.append((child, depth + 1)) }
            }
        }
        FileHandle.standardOutput.write(Data(out.utf8))
        exit(0)
    }

    // MARK: scan

    let output = takeValue("-o", "--output")
    let workers = takeValue("--workers").flatMap(Int.init)
    let reproducible = takeFlag("--reproducible")
    let verify = takeFlag("--verify")
    let showIssues = takeFlag("--issues")
    let showProgress = takeFlag("--progress")
    let quiet = takeFlag("--quiet")
    guard arguments.count == 1 else { fail("expected one folder, got: \(arguments)") }
    let folder = arguments[0]

    // this tool never downloads cloud files, in any thread
    _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

    var options = Scanner.Options()
    if let workers { options.workerCount = workers }
    let scanner = Scanner(path: folder, options: options)

    if showProgress {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler {
            let p = scanner.progress
            guard !p.isFinished else { return }
            var line = "\r\(p.items) items, \(formatBytes(p.allocatedBytes))"
            if let expected = p.expectedItemCount, expected > 0 {
                line += String(format: " (%.0f%%)", min(100, Double(p.items) * 100 / Double(expected)))
            }
            FileHandle.standardError.write(Data((line + "   ").utf8))
        }
        timer.resume()
    }

    let result: ScanResult
    do { result = try scanner.scan() } catch { fail("scan failed: \(error)") }
    if showProgress { FileHandle.standardError.write(Data("\n".utf8)) }

    var snapshot = result.snapshot
    if reproducible {
        snapshot.scanDate = Date(timeIntervalSince1970: 0)
        snapshot.volume = nil
    }

    if let output {
        let t0 = Date()
        do { try snapshot.write(to: URL(fileURLWithPath: output), compression: compression) } catch { fail("cannot write \(output): \(error)") }
        if !quiet { print(String(format: "wrote:       %@ in %.1f ms", output, Date().timeIntervalSince(t0) * 1000)) }
    }

    if !quiet {
        printSummary(snapshot)
        let items = snapshot.nodeCount - 1
        print(String(format: "scan time:   %.3f s (walk %.3f s, assemble %.3f s), %.0f items/s, %d workers, %d kind lookups",
                     result.duration, result.walkDuration, result.duration - result.walkDuration,
                     Double(items) / result.duration, options.workerCount, result.kindLookups))
        print("issues:      \(result.issueCount) (\(result.entryErrors) entry errors)")
        print("peak memory: \(peakRSS() / 1_048_576) MB RSS, \(peakRSS() / UInt64(max(1, snapshot.nodeCount))) B per node")
    }
    if showIssues || (!quiet && result.issueCount > 0) {
        let limit = showIssues ? result.issues.count : min(10, result.issues.count)
        for issue in result.issues.prefix(limit) { print("  \(issue)") }
        if limit < result.issueCount { print("  ... \(result.issueCount - limit) more (use --issues)") }
    }

    if verify {
        let t0 = Date()
        let report = Verifier.verify(result.snapshot)
        print(report)
        print(String(format: "verify time: %.2f s", Date().timeIntervalSince(t0)))
        print(report.passed ? "VERIFY: PASS" : "VERIFY: FAIL")
        exit(report.passed ? 0 : 2)
    }
}

runCLI()
