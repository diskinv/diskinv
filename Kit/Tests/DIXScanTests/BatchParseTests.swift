//
//  BatchParseTests.swift
//  DIXScanTests
//
//  Feeds the getattrlistbulk parser synthetic batches, to cover what a test
//  machine may not have: cloud placeholders (SF_DATALESS) both as files and
//  folders, mount points and automount triggers, per-entry errors, missing
//  attributes, unusual object types and truncated batches.
//
//  GPL v3
//

import Foundation
import Testing
import DIXCore
@testable import DIXScan

private struct FakeEntry {
    var name: String
    var type: UInt32                     // vnode type: 1 reg, 2 dir, 5 lnk, 3 blk, 4 chr, 6 sock, 7 fifo
    var bsdFlags: UInt32 = 0
    var error: UInt32? = nil
    var mountStatus: UInt32 = 0
    var linkCount: UInt32 = 1
    var allocated: Int64? = 4096
    var length: Int64? = 100
    var fileID: UInt64 = 1
    var onlyName = false                 // an entry that failed: just error + name

    func bytes() -> [UInt8] {
        var common: UInt32 = 0x8000_0000 | 0x1       // RETURNED_ATTRS | NAME
        if error != nil { common |= 0x2000_0000 }
        if !onlyName { common |= 0x2 | 0x8 | 0x4000 | 0x20000 | 0x40000 | 0x0200_0000 }
        let isDirectory = type == 2
        let dirAttrs: UInt32 = isDirectory && !onlyName ? 0x4 : 0
        var fileAttrs: UInt32 = 0
        if !isDirectory && !onlyName {
            fileAttrs = 0x1
            if allocated != nil { fileAttrs |= 0x4 }
            if length != nil { fileAttrs |= 0x200 }
        }
        var body: [UInt8] = []
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { body.append(contentsOf: $0) } }
        put(common); put(UInt32(0)); put(dirAttrs); put(fileAttrs); put(UInt32(0))
        if let error { put(error) }
        let nameReferenceAt = body.count
        put(Int32(0)); put(UInt32(0))        // patched below
        if !onlyName {
            put(UInt32(16777234))            // device
            put(type)
            body.append(contentsOf: [UInt8](repeating: 0, count: 32))   // Finder info
            put(UInt32(0o644))
            put(bsdFlags)
            put(fileID)
            if isDirectory { put(mountStatus) }
            if !isDirectory {
                put(linkCount)
                if let allocated { put(allocated) }
                if let length { put(length) }
            }
        }
        let nameBytes = Array(name.utf8) + [0]
        let nameAt = body.count
        body.append(contentsOf: nameBytes)
        while body.count % 4 != 0 { body.append(0) }
        withUnsafeBytes(of: Int32(nameAt - nameReferenceAt)) { body.replaceSubrange(nameReferenceAt ..< nameReferenceAt + 4, with: $0) }
        withUnsafeBytes(of: UInt32(nameBytes.count)) { body.replaceSubrange(nameReferenceAt + 4 ..< nameReferenceAt + 8, with: $0) }
        var entry: [UInt8] = []
        withUnsafeBytes(of: UInt32(body.count + 4)) { entry.append(contentsOf: $0) }
        return entry + body
    }
}

private func parse(_ entries: [FakeEntry], claim: Int? = nil)
    -> (DirResult, [(entry: Int, path: ContiguousArray<UInt8>)], [ScanIssue], [String: RawEntry]) {
    let reader = DirectoryReader(kinds: KindRegistry())
    let batch = entries.flatMap { $0.bytes() }
    let result = DirResult(job: 0)
    var subdirectories: [(entry: Int, path: ContiguousArray<UInt8>)] = []
    var issues: [ScanIssue] = []
    batch.withUnsafeBytes { raw in
        reader.parse(raw, count: claim ?? entries.count, into: result, path: ContiguousArray("/fake".utf8),
                     subdirectories: &subdirectories, issues: &issues)
    }
    var byName: [String: RawEntry] = [:]
    for e in result.entries {
        byName[String(decoding: result.names[Int(e.nameOffset) ..< Int(e.nameOffset) + Int(e.nameLength)], as: UTF8.self)] = e
    }
    return (result, subdirectories, issues, byName)
}

@Test func cloudPlaceholdersAreFlaggedAndNeverDescended() {
    let (_, subdirectories, issues, e) = parse([
        FakeEntry(name: "evicted.mov", type: 1, bsdFlags: SF_DATALESS_, allocated: 0, length: 5_000_000_000),
        FakeEntry(name: "evicted-folder", type: 2, bsdFlags: SF_DATALESS_),
        FakeEntry(name: "local.txt", type: 1, allocated: 8192, length: 6000),
        FakeEntry(name: "local-folder", type: 2),
    ])
    #expect(issues.isEmpty)
    let file = e["evicted.mov"]!
    #expect(NodeFlags(rawValue: file.flags).contains(.cloudPlaceholder))
    #expect(file.allocated == 0 && file.logical == 5_000_000_000)
    let folder = e["evicted-folder"]!
    #expect(NodeFlags(rawValue: folder.flags) == [.directory, .cloudPlaceholder])
    #expect(!NodeFlags(rawValue: e["local.txt"]!.flags).contains(.cloudPlaceholder))
    // only the local folder is queued for reading
    #expect(subdirectories.map { String(decoding: $0.path, as: UTF8.self) } == ["/fake/local-folder"])
}

@Test func mountPointsAndTriggersAreNotDescended() {
    let (_, subdirectories, _, e) = parse([
        FakeEntry(name: "mounted", type: 2, mountStatus: 0x1),
        FakeEntry(name: "automount", type: 2, mountStatus: 0x2),
        FakeEntry(name: "plain", type: 2),
    ])
    #expect(NodeFlags(rawValue: e["mounted"]!.flags).contains(.mountPoint))
    #expect(NodeFlags(rawValue: e["automount"]!.flags).contains(.mountPoint))
    #expect(subdirectories.count == 1)
}

@Test func failedAndPartialEntriesAreStillRecorded() {
    let (result, _, issues, e) = parse([
        FakeEntry(name: "broken", type: 1, error: UInt32(EIO), onlyName: true),
        FakeEntry(name: "no-alloc", type: 1, allocated: nil, length: 77),
        FakeEntry(name: "fifo", type: 7, allocated: 0, length: 0),
        FakeEntry(name: "socket", type: 6, allocated: 0, length: 0),
        FakeEntry(name: "chardev", type: 4, allocated: 0, length: 0),
        FakeEntry(name: "blockdev", type: 3, allocated: 0, length: 0),
        FakeEntry(name: "whiteout", type: 9, allocated: 0, length: 0),
        FakeEntry(name: "linked", type: 1, linkCount: 3, fileID: 42),
    ])
    #expect(result.entries.count == 8)
    #expect(e["broken"]!.allocated == 0)
    #expect(issues.map(\.kind) == [.entryError])
    #expect(issues.first?.path == "/fake/broken")
    #expect(e["no-alloc"]!.allocated == 0 && e["no-alloc"]!.logical == 77)
    for name in ["fifo", "socket", "chardev", "blockdev", "whiteout"] {
        #expect(!NodeFlags(rawValue: e[name]!.flags).contains(.directory), "\(name)")
    }
    #expect(result.links.count == 1 && result.links[0].fileID == 42)
}

@Test func aTruncatedBatchKeepsWhatWasReadAndSaysSo() {
    let (result, _, issues, _) = parse([
        FakeEntry(name: "one", type: 1),
        FakeEntry(name: "two", type: 1),
    ], claim: 3)
    #expect(result.entries.count == 2)
    #expect(result.unreadable)
    #expect(issues.map(\.kind) == [.incompleteFolder])
}

@Test func extensionKeys() {
    func key(_ s: String, dir: Bool = false) -> KindKey? {
        Array(s.utf8).withUnsafeBytes { KindKey.forExtension(of: $0, directory: dir) }
    }
    // case-insensitive, except that all-capitals spellings are a key of their
    // own (they skip the override table; see KindTests)
    #expect(key("a.Txt") == key("b.txt"))
    #expect(key("a.TXT") != key("b.txt"))
    #expect(key("a.TXT")?.extensionString == "txt")
    #expect(key("a.MP4") == key("b.MP4"))
    #expect(key("a.txt")?.extensionString == "txt")
    #expect(key(".bashrc") == nil)
    #expect(key("noext") == nil)
    #expect(key("trailing.") == nil)
    #expect(key("a.b c") == nil)
    #expect(key("x." + String(repeating: "e", count: 16))?.extensionString == String(repeating: "e", count: 16))
    #expect(key("x." + String(repeating: "e", count: 17)) == nil)
    #expect(key("a.app", dir: true) != key("a.app"))
}
