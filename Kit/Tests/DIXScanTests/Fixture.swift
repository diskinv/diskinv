//
//  Fixture.swift
//  DIXScanTests
//
//  Builds a directory tree full of the cases a scanner gets wrong: hard
//  links, symlink loops, unreadable folders, packages, odd names, deep
//  nesting past PATH_MAX, sparse files, FIFOs, many entries in one folder.
//  Fixtures go under $DIX_FIXTURES (default: the temporary directory).
//
//  GPL v3
//

import Foundation
import DIXCore

final class Fixture {
    let root: String
    /// names the file system accepted (some may be refused, e.g. invalid UTF-8)
    private(set) var notes: [String] = []
    private(set) var deepDepth = 0
    private(set) var invalidUTF8Created = false
    private(set) var socketCreated = false

    static func base() -> String {
        let base = ProcessInfo.processInfo.environment["DIX_FIXTURES"] ?? NSTemporaryDirectory()
        guard let resolved = realpath(base, nil) else { return base }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    init(_ name: String) {
        root = Self.base() + "/dixfx-\(name)-\(getpid())-\(UInt32.random(in: 0 ... .max))"
        mkdir(root, 0o755)
    }

    deinit {
        // restore permissions so the tree can be removed
        for dir in ["locked", "locked-empty"] { chmod(root + "/" + dir, 0o755) }
        removeDeep(root)
    }

    /// FileManager cannot remove paths beyond PATH_MAX; walk with fds.
    private func removeDeep(_ path: String) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd >= 0 { removeContents(fd); close(fd) }
        rmdir(path)
    }

    private func removeContents(_ fd: Int32) {
        guard let dir = fdopendir(dup(fd)) else { return }
        defer { closedir(dir) }
        var names: [(String, Bool)] = []
        while let entry = readdir(dir) {
            var nameTuple = entry.pointee.d_name
            let name = withUnsafeBytes(of: &nameTuple) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            names.append((name, entry.pointee.d_type == DT_DIR))
        }
        for (name, isDirectory) in names {
            if isDirectory {
                fchmodat(fd, name, 0o755, AT_SYMLINK_NOFOLLOW)
                let sub = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if sub >= 0 { removeContents(sub); close(sub) }
                unlinkat(fd, name, AT_REMOVEDIR)
            } else {
                unlinkat(fd, name, 0)
            }
        }
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    func dir(_ relative: String) { mkdir(path(relative), 0o755) }

    func file(_ relative: String, bytes: Int, byte: UInt8 = 0x61) {
        let data = Data(repeating: byte, count: bytes)
        FileManager.default.createFile(atPath: path(relative), contents: data)
    }

    /// The standard fixture.
    static func standard() -> Fixture {
        let f = Fixture("std")
        // plain files and empty folders
        f.file("small.txt", bytes: 10)
        f.file("big.bin", bytes: 300_000, byte: 0x5A)
        f.file("empty-file", bytes: 0)
        f.dir("empty")
        f.dir("nested-empty"); f.dir("nested-empty/a"); f.dir("nested-empty/a/b")
        f.file(".hidden-dotfile", bytes: 5000)
        f.file("flag-hidden.dat", bytes: 4096)
        chflags(f.path("flag-hidden.dat"), UInt32(UF_HIDDEN))

        // hard links: one inode, four names in three folders
        f.dir("links"); f.dir("links/a"); f.dir("links/b"); f.dir("links/c")
        f.file("links/b/x", bytes: 50_000)
        link(f.path("links/b/x"), f.path("links/a/x"))
        link(f.path("links/b/x"), f.path("links/c/y"))
        link(f.path("links/b/x"), f.path("links/a/w"))

        // symlinks: a loop, a self-loop, to a folder, to /System, dangling
        f.dir("symlinks")
        symlink("loop2", f.path("symlinks/loop1"))
        symlink("loop1", f.path("symlinks/loop2"))
        symlink(".", f.path("symlinks/self"))
        symlink("../links", f.path("symlinks/to-links"))
        symlink("/System", f.path("symlinks/to-system"))
        symlink("does-not-exist", f.path("symlinks/dangling"))

        // unreadable folders (content must not appear) and an unreadable file
        f.dir("locked"); f.file("locked/secret", bytes: 1000)
        chmod(f.path("locked"), 0)
        f.dir("locked-empty"); chmod(f.path("locked-empty"), 0)
        f.file("no-perm-file", bytes: 2000); chmod(f.path("no-perm-file"), 0)

        // packages: by extension, and by the Finder bundle bit
        f.dir("Foo.app"); f.dir("Foo.app/Contents"); f.dir("Foo.app/Contents/MacOS")
        f.file("Foo.app/Contents/Info.plist", bytes: 300)
        f.file("Foo.app/Contents/MacOS/Foo", bytes: 70_000)
        chmod(f.path("Foo.app/Contents/MacOS/Foo"), 0o755)
        f.dir("Bundled"); f.file("Bundled/inside", bytes: 100)
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[8] = 0x20      // kHasBundle, big-endian 0x2000
        setxattr(f.path("Bundled"), "com.apple.FinderInfo", &finderInfo, 32, 0, 0)
        f.dir("not.a-package.dir"); f.file("not.a-package.dir/f", bytes: 1)

        // odd names
        f.dir("names")
        for name in ["café", "日本語のファイル名", "emoji 😀🎉", "new\nline", "tab\there", "back\\slash",
                     " leading space", "trailing dots..", "-dash", "UPPER.TXT", "noext", ".dotonly",
                     "a.tar.gz", "x.verylongextensionname", String(repeating: "n", count: 255)] {
            f.file("names/" + name, bytes: 7)
        }
        // Unicode normalization: NFD form of a different word, kept byte for byte
        f.file("names/" + "re\u{0301}sume\u{0301}", bytes: 3)
        // invalid UTF-8 (APFS normally refuses it; record whether it worked)
        var invalid = Array(f.path("names/bad-").utf8) + [0xFF, 0xFE, 0x41, 0]
        let fd = invalid.withUnsafeMutableBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) { open($0, O_CREAT | O_WRONLY, 0o644) }
        }
        if fd >= 0 { close(fd); f.invalidUTF8Created = true }
        // legacy iCloud stub
        f.file("names/.Report.pdf.icloud", bytes: 180)

        // special files
        f.dir("special")
        mkfifo(f.path("special/fifo"), 0o644)
        f.socketCreated = f.makeSocket(f.path("special/sock"))

        // sparse file: 1 GB long, nothing allocated
        let sparse = open(f.path("sparse.img"), O_CREAT | O_WRONLY, 0o644)
        ftruncate(sparse, 1 << 30)
        close(sparse)

        // a resource fork
        f.file("with-rsrc", bytes: 1000)
        var fork = [UInt8](repeating: 0x42, count: 40_000)
        setxattr(f.path("with-rsrc"), XATTR_RESOURCEFORK_NAME, &fork, fork.count, 0, 0)

        // many entries in one folder: several getattrlistbulk batches
        f.dir("many")
        for i in 0 ..< 3000 {
            f.file("many/" + String(format: "%05d-", i) + String(repeating: "m", count: 180), bytes: i % 7)
        }

        // deep nesting, past PATH_MAX (made with mkdirat, since paths that long cannot be used)
        f.deepDepth = f.makeDeep(levels: 120, component: String(repeating: "d", count: 30))
        return f
    }

    private func makeSocket(_ path: String) -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0
    }

    /// returns the depth reached
    private func makeDeep(levels: Int, component: String) -> Int {
        dir("deep")
        var fd = open(path("deep"), O_RDONLY | O_DIRECTORY)
        var depth = 0
        for i in 0 ..< levels {
            guard mkdirat(fd, component, 0o755) == 0 else { break }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY)
            close(fd)
            guard next >= 0 else { return depth }
            fd = next
            depth += 1
            if i == levels - 1 {
                let leaf = openat(fd, "leaf.txt", O_CREAT | O_WRONLY, 0o644)
                if leaf >= 0 { _ = write(leaf, "deep", 4); close(leaf) }
            }
        }
        close(fd)
        return depth
    }
}

extension Snapshot {
    /// node for a path relative to the root ("" = root), by walking names
    func node(_ relative: String) -> NodeIndex? {
        var node = Snapshot.root
        if relative.isEmpty { return node }
        for component in relative.split(separator: "/", omittingEmptySubsequences: false) {
            let target = Array(component.utf8)
            guard let next = children(of: node).first(where: { nameBytes(of: $0) == target }) else { return nil }
            node = next
        }
        return node
    }

    func nameBytes(of node: NodeIndex) -> [UInt8] {
        let start = Int(nameOffset[node])
        return Array(nameBytes[start ..< start + Int(nameLength[node])])
    }

    func depth(of node: NodeIndex) -> Int {
        var d = 0, n = node
        while n != Snapshot.root { n = Int(parent[n]); d += 1 }
        return d
    }
}
