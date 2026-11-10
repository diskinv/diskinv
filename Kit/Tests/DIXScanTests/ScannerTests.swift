import Foundation
import Testing
import DIXCore
@testable import DIXScan

private func scan(_ path: String, workers: Int = ProcessInfo.processInfo.activeProcessorCount) throws -> ScanResult {
    try Scanner(path: path, options: .init(workerCount: workers)).scan()
}

@Suite struct FixtureScanTests {
    @Test func everythingIsFoundAndTheOracleAgrees() throws {
        let f = Fixture.standard()
        let result = try scan(f.root)
        let s = result.snapshot
        #expect(s.validate() == nil)

        let report = Verifier.verify(s)
        #expect(report.passed, "\(report)")
        #expect(report.changedEntries == 0)
        // the oracle saw the same number of entries as the snapshot holds
        #expect(report.entriesChecked == s.nodeCount - 1)
        // and the scanner's total is the oracle's du-style total
        #expect(report.oracleAllocated == s.allocatedSize[0])
        #expect(report.oracleLogical == s.logicalSize[0])
    }

    @Test func hardLinksCountOnceAndTheSmallestPathKeepsTheSize() throws {
        let f = Fixture.standard()
        let s = try scan(f.root).snapshot
        let keeper = try #require(s.node("links/a/w"))
        #expect(!s.flags[keeper].contains(.hardLinkDuplicate))
        #expect(s.allocatedSize[keeper] > 0)
        for dup in ["links/a/x", "links/b/x", "links/c/y"] {
            let node = try #require(s.node(dup))
            #expect(s.flags[node].contains(.hardLinkDuplicate), "\(dup)")
            #expect(s.allocatedSize[node] == 0)
            #expect(s.logicalSize[node] == 50_000)
        }
        #expect(s.summary.hardLinkDuplicates == 3)
        // whatever the worker count, the same link keeps the size
        for workers in [1, 2, 7] {
            let again = try scan(f.root, workers: workers).snapshot
            #expect(!again.flags[try #require(again.node("links/a/w"))].contains(.hardLinkDuplicate))
        }
    }

    @Test func symlinksAreRecordedNotFollowed() throws {
        let f = Fixture.standard()
        let s = try scan(f.root).snapshot
        for name in ["loop1", "loop2", "self", "to-links", "to-system", "dangling"] {
            let node = try #require(s.node("symlinks/" + name), "\(name)")
            #expect(s.flags[node].contains(.symlink))
            #expect(!s.isDirectory(node))
            #expect(s.childCount[node] == 0)
        }
        #expect(s.kind(of: s.node("symlinks/loop1")!).identifier == "public.symlink")
    }

    @Test func unreadableFoldersAreFlaggedAndReported() throws {
        let f = Fixture.standard()
        let result = try scan(f.root)
        let s = result.snapshot
        for name in ["locked", "locked-empty"] {
            let node = try #require(s.node(name))
            #expect(s.flags[node].contains(.unreadable))
            #expect(s.childCount[node] == 0)
        }
        #expect(s.node("locked/secret") == nil)
        #expect(result.summary.unreadableFolders == 2)
        #expect(result.issues.filter { $0.kind == .unreadableFolder }.count == 2)
        #expect(result.issues.allSatisfy { $0.errno == EACCES })
        // an unreadable file is still listed with its size
        #expect(s.logicalSize[try #require(s.node("no-perm-file"))] == 2000)
    }

    @Test func packagesAreFlaggedAndDescended() throws {
        let f = Fixture.standard()
        let s = try scan(f.root).snapshot
        let app = try #require(s.node("Foo.app"))
        #expect(s.flags[app].contains(.package))
        #expect(s.flags[app].contains(.directory))
        #expect(s.kind(of: app).identifier == "com.apple.application-bundle")
        #expect(s.node("Foo.app/Contents/MacOS/Foo") != nil)
        let bundled = try #require(s.node("Bundled"))
        #expect(s.flags[bundled].contains(.package))
        #expect(s.node("Bundled/inside") != nil)
        let plain = try #require(s.node("not.a-package.dir"))
        #expect(!s.flags[plain].contains(.package))
        #expect(s.kindIndex[plain] == 0)
        #expect(s.kinds[0].identifier == "public.folder")
    }

    @Test func oddNamesSurviveByteForByte() throws {
        let f = Fixture.standard()
        let s = try scan(f.root).snapshot
        let names = try #require(s.node("names"))
        let scanned = Set(s.children(of: names).map { s.nameBytes(of: $0) })
        // the oracle: readdir's names, as raw bytes
        var listed = Set<[UInt8]>()
        let dir = opendir(f.path("names"))!
        while let entry = readdir(dir) {
            var tuple = entry.pointee.d_name
            let bytes = withUnsafeBytes(of: &tuple) { Array($0.prefix(Int(entry.pointee.d_namlen))) }
            if bytes != [46] && bytes != [46, 46] { listed.insert(bytes) }
        }
        closedir(dir)
        #expect(scanned == listed)
        #expect(scanned.contains(Array("re\u{0301}sume\u{0301}".utf8)))
        #expect(scanned.contains(Array(String(repeating: "n", count: 255).utf8)))
        // kinds: by extension, case-insensitively; executables without one
        #expect(s.kind(of: s.node("names/UPPER.TXT")!).identifier == "public.plain-text")
        #expect(s.kind(of: s.node("names/a.tar.gz")!).identifier == "org.gnu.gnu-zip-archive")
        #expect(s.kind(of: s.node("Foo.app/Contents/MacOS/Foo")!).identifier == "public.unix-executable")
        #expect(s.kind(of: s.node("names/noext")!).name == "Document")
        // legacy iCloud stub: a placeholder, with the kind of the real file
        let stub = try #require(s.node("names/.Report.pdf.icloud"))
        #expect(s.flags[stub].contains(.cloudPlaceholder))
        #expect(s.kind(of: stub).identifier == "com.adobe.pdf")
    }

    @Test func specialFilesSparseFilesAndDeepTrees() throws {
        let f = Fixture.standard()
        let s = try scan(f.root).snapshot
        #expect(s.kind(of: try #require(s.node("special/fifo"))).name == "Named Pipe")
        if f.socketCreated { #expect(s.node("special/sock") != nil) }
        let sparse = try #require(s.node("sparse.img"))
        #expect(s.logicalSize[sparse] == 1 << 30)
        #expect(s.allocatedSize[sparse] < 1 << 20)
        // resource fork counts in allocated, like du
        let rsrc = try #require(s.node("with-rsrc"))
        #expect(s.allocatedSize[rsrc] >= 40_000)
        #expect(s.logicalSize[rsrc] == 1000)
        // 3000 entries in one folder
        #expect(s.childCount[try #require(s.node("many"))] == 3000)
        // past PATH_MAX
        #expect(f.deepDepth == 120)
        let leaf = try #require((0 ..< s.nodeCount).first { s.nameBytes(of: $0) == Array("leaf.txt".utf8) })
        #expect(s.depth(of: leaf) == 1 + f.deepDepth + 1)
        #expect(s.path(of: leaf).utf8.count > Int(PATH_MAX))
        #expect(s.node("empty").map { s.isDirectory($0) && s.childCount[$0] == 0 } == true)
    }

    @Test func scansAreDeterministicAcrossRunsAndWorkerCounts() throws {
        let f = Fixture.standard()
        var files: [Data] = []
        for workers in [1, 4, ProcessInfo.processInfo.activeProcessorCount, 32] {
            var s = try scan(f.root, workers: workers).snapshot
            s.scanDate = Date(timeIntervalSince1970: 0)
            s.volume = nil
            files.append(try s.fileData())
        }
        #expect(Set(files).count == 1)
    }

    @Test func fileRoundTripKeepsEverything() throws {
        let f = Fixture.standard()
        let s = try scan(f.root).snapshot
        let url = URL(fileURLWithPath: f.path("out.dixsnap"))
        try s.write(to: url)
        let loaded = try Snapshot(contentsOf: url)
        #expect(loaded.rootPath == s.rootPath)
        #expect(loaded.scanDate == s.scanDate)
        #expect(loaded.volume == s.volume)
        #expect(loaded.parent == s.parent && loaded.firstChild == s.firstChild && loaded.childCount == s.childCount)
        #expect(loaded.allocatedSize == s.allocatedSize && loaded.logicalSize == s.logicalSize)
        #expect(loaded.nameOffset == s.nameOffset && loaded.nameLength == s.nameLength && loaded.nameBytes == s.nameBytes)
        #expect(loaded.kindIndex == s.kindIndex && loaded.kinds == s.kinds && loaded.flags == s.flags)
        #expect(try loaded.fileData() == s.fileData())
    }

    @Test func progressAndCancel() throws {
        let f = Fixture.standard()
        let scanner = Scanner(path: f.root)
        let result = try scanner.scan()
        let p = scanner.progress
        #expect(p.isFinished)
        #expect(p.items == result.snapshot.nodeCount - 1)
        // live counters run before hard links are resolved, so they can only be larger
        #expect(p.allocatedBytes >= result.snapshot.allocatedSize[0])
        #expect(p.logicalBytes == result.snapshot.logicalSize[0])
        #expect(p.expectedItemCount == nil)     // not a volume root

        let cancelled = Scanner(path: f.root)
        cancelled.cancel()
        #expect(throws: ScanError.self) { try cancelled.scan() }

        // cancel from another thread while scanning a bigger tree
        let racing = Scanner(path: "/usr", options: .init(workerCount: 2))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { racing.cancel() }
        do {
            _ = try racing.scan()       // may finish first on a fast machine
        } catch ScanError.cancelled {
        }
    }

    @Test func rootErrors() {
        #expect(throws: ScanError.self) { try Scanner(path: "/no/such/folder").scan() }
        #expect(throws: ScanError.self) { try Scanner(path: "/etc/hosts").scan() }
    }
}

@Suite struct VolumeTests {
    /// "/" is read one level only: firmlinks (/Users, /Applications) are
    /// ordinary folders there, and /System/Volumes/Data is a mount point, so a
    /// scan of "/" reaches the Data volume through the firmlinks exactly once.
    @Test func firmlinksAreFoldersAndTheDataVolumeIsAMountPoint() throws {
        let reader = DirectoryReader(kinds: KindRegistry())
        func entries(_ path: String) -> [String: NodeFlags] {
            var subdirectories: [(entry: Int, path: ContiguousArray<UInt8>)] = []
            var issues: [ScanIssue] = []
            let (result, fd) = reader.read(job: 0, path: ContiguousArray(path.utf8), fd: -1,
                                           subdirectories: &subdirectories, issues: &issues)
            if fd >= 0 { close(fd) }
            var out: [String: NodeFlags] = [:]
            for e in result.entries {
                let name = String(decoding: result.names[Int(e.nameOffset) ..< Int(e.nameOffset) + Int(e.nameLength)], as: UTF8.self)
                out[name] = NodeFlags(rawValue: e.flags)
            }
            return out
        }
        let root = entries("/")
        for firmlink in ["Users", "Applications", "Library"] {
            let flags = try #require(root[firmlink])
            #expect(flags.contains(.directory) && !flags.contains(.mountPoint), "\(firmlink)")
        }
        #expect(root["dev"]?.contains(.mountPoint) == true)
        #expect(entries("/System/Volumes")["Data"]?.contains(.mountPoint) == true)
    }

    @Test func expectedItemCountForVolumeRoots() {
        let root = Scanner.expectedItemCount(forRoot: "/")
        let data = Scanner.expectedItemCount(forRoot: "/System/Volumes/Data")
        #expect(root != nil && data != nil)
        #expect(root! > data!)
        #expect(Scanner.expectedItemCount(forRoot: "/usr") == nil)
    }
}
