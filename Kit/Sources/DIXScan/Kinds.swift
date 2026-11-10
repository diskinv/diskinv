//
//  Kinds.swift
//  DIXScan
//
//  File kinds, resolved once per distinct extension and never per file.
//
//  LaunchServices (behind UTType) takes a global lock on every lookup; the
//  previous app's scan spent most of its worker time waiting on it. Here each
//  worker keeps its own small cache keyed by the lowercased extension packed
//  into two integers, so the hot path is one dictionary lookup without any
//  allocation, and LaunchServices is asked once per extension per scan.
//
//  Some extensions mean one thing to macOS and another on a developer's disk
//  (".ts" is an MPEG-2 Transport Stream to LaunchServices, and 626,000
//  TypeScript files in one node_modules-heavy folder). KindRegistry.overrides
//  settles those, for lowercase spellings only: a camcorder's "CLIP.MTS" or a
//  recorder's "SHOW.TS" is all capitals and keeps the system's type.
//
//  GPL v3
//

import Foundation
import UniformTypeIdentifiers
import DIXCore

/// What a kind is looked up by. The extension (at most 16 ASCII bytes,
/// lowercased) is packed into `low`/`high`; `category` says how it is used.
struct KindKey: Hashable {
    var low: UInt64
    var high: UInt64
    var category: UInt8
    var length: UInt8

    enum Category: UInt8 {
        case fileExtension = 1      // a file "x.ext"
        case directoryExtension     // a directory "x.ext": a package if its UTType conforms to .package
        case special                // low = SpecialKind
        case fileExtensionAllCaps   // a file "X.EXT" (letters all capitals): the system's type, no override
    }

    enum SpecialKind: UInt64 {
        case document = 1, unixExecutable, symlink, package, fifo, socket, characterDevice, blockDevice, other
    }

    static func special(_ kind: SpecialKind) -> KindKey {
        KindKey(low: kind.rawValue, high: 0, category: Category.special.rawValue, length: 0)
    }

    /// The key for the extension of `name` (bytes after the last dot, if the
    /// dot is not the first byte), or nil when there is no usable extension.
    static func forExtension(of name: UnsafeRawBufferPointer, directory: Bool) -> KindKey? {
        let count = name.count
        var dot = count - 1
        while dot > 0 && name[dot] != UInt8(ascii: ".") { dot -= 1 }
        guard dot > 0 else { return nil }
        let length = count - dot - 1
        guard length > 0 && length <= 16 else { return nil }
        var low: UInt64 = 0, high: UInt64 = 0
        var upper = false, lower = false
        for i in 0 ..< length {
            var byte = name[dot + 1 + i]
            // printable ASCII only, no spaces: anything else is not a real extension
            guard byte > 0x20 && byte < 0x7F else { return nil }
            if byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") {
                byte += 32
                upper = true
            } else if byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z") {
                lower = true
            }
            if i < 8 { low |= UInt64(byte) << (8 * UInt64(i)) } else { high |= UInt64(byte) << (8 * UInt64(i - 8)) }
        }
        let category: Category = directory ? .directoryExtension : (upper && !lower ? .fileExtensionAllCaps : .fileExtension)
        return KindKey(low: low, high: high, category: category.rawValue, length: UInt8(length))
    }

    var extensionString: String {
        var bytes: [UInt8] = []
        for i in 0 ..< Int(length) {
            bytes.append(UInt8(truncatingIfNeeded: (i < 8 ? low >> (8 * UInt64(i)) : high >> (8 * UInt64(i - 8)))))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// The scan-wide table of kinds. Slots are handed out in whatever order the
/// workers meet extensions; `finalTable()` turns them into a sorted,
/// deterministic kind table.
final class KindRegistry: @unchecked Sendable {
    /// slot 0 is always the folder kind
    static let folderSlot: UInt32 = 0

    private let lock = NSLock()
    private var slots: [UInt32: FileKind] = [:]     // slot -> kind
    private var byKey: [KindKey: UInt32] = [:]
    /// for directory keys: is that kind a package?
    private var packageSlots: Set<UInt32> = []
    private var nextSlot: UInt32 = 1
    private(set) var lookups = 0

    init() {
        slots[Self.folderSlot] = Self.describe(.folder)
    }

    /// slot for `key`, resolving it through UTType the first time.
    /// Returns (slot, isPackage); isPackage is only meaningful for directory keys.
    func slot(for key: KindKey) -> (UInt32, Bool) {
        lock.lock()
        if let slot = byKey[key] {
            let package = packageSlots.contains(slot)
            lock.unlock()
            return (slot, package)
        }
        lock.unlock()

        // resolve outside the lock; two workers racing on the same key both
        // compute the same answer and the first insert wins
        let (kind, package) = Self.resolve(key)

        lock.lock()
        defer { lock.unlock() }
        if let slot = byKey[key] { return (slot, packageSlots.contains(slot)) }
        lookups += 1
        if key.category == KindKey.Category.directoryExtension.rawValue && !package {
            byKey[key] = Self.folderSlot
            return (Self.folderSlot, false)
        }
        let slot = nextSlot
        nextSlot += 1
        slots[slot] = kind
        byKey[key] = slot
        if package { packageSlots.insert(slot) }
        return (slot, package)
    }

    /// UTType descriptions are sometimes lowercase ("folder"); Finder shows
    /// kinds capitalized ("Folder").
    static func describe(_ type: UTType) -> FileKind {
        let name = type.localizedDescription ?? type.identifier
        return FileKind(identifier: type.identifier, name: name.prefix(1).uppercased() + name.dropFirst())
    }

    /// Extensions whose system type is wrong on a developer's disk, checked
    /// before UTType for lowercase spellings. Measured on ~/_greek, ~/a, ~/b
    /// and /Applications (2026-11): the left side is what LaunchServices said.
    ///
    /// - ts, mts, cts: "MPEG-2 Transport Stream", "AVCHD MPEG-2 Transport
    ///   Stream", unknown. TypeScript and its ES-module / CommonJS variants
    ///   (also .d.ts): 703,000 files, 5.1 GB; no transport stream among them.
    /// - tsx: "Script" (some app's description of com.microsoft.typescript).
    /// - cjs, jsx: unknown ("CJS File"). CommonJS modules and JSX, shown as
    ///   JavaScript like .js and .mjs.
    /// - bin: "MacBinary archive", a 1990s format; today's .bin files are
    ///   firmware, model weights and disc images (1.8 GB, 1,325 files).
    /// - pkl: "Pkl Source" (Apple's config language); on disk these were
    ///   Python pickles (255 MB in 16 files).
    ///
    /// Left alone, though they are ambiguous too: .m (Objective-C, not
    /// MATLAB), .h, .pl (Perl), .r (Rez), .fs (GLSL fragment shader, not F#),
    /// .exs (Logic EXS instrument, not Elixir), .pxd (Pixelmator, not Cython),
    /// .sql; and extensions macOS does not know at all keep Finder's "RS File"
    /// style (.rs, .go, .mod, .d, .sol, .map).
    static let overrides: [String: FileKind] = {
        let typeScript = FileKind(identifier: "com.microsoft.typescript", name: "TypeScript")
        let javaScript = describe(.javaScript)
        return [
            "ts": typeScript, "mts": typeScript, "cts": typeScript, "tsx": typeScript,
            "cjs": javaScript, "jsx": javaScript,
            "bin": FileKind(identifier: "", name: "BIN File"),
            "pkl": FileKind(identifier: "", name: "Python Pickle"),
        ]
    }()

    private static func resolve(_ key: KindKey) -> (FileKind, Bool) {
        switch KindKey.Category(rawValue: key.category) {
        case .fileExtension, .fileExtensionAllCaps:
            let ext = key.extensionString
            if key.category == KindKey.Category.fileExtension.rawValue, let kind = overrides[ext] {
                return (kind, false)
            }
            if let type = UTType(filenameExtension: ext), !type.isDynamic {
                return (describe(type), false)
            }
            // unknown extension: no identifier, Finder-style "EXT File"
            return (FileKind(identifier: "", name: ext.uppercased() + " File"), false)
        case .directoryExtension:
            if let type = UTType(filenameExtension: key.extensionString, conformingTo: .package),
               !type.isDynamic, type.conforms(to: .package) {
                return (describe(type), true)
            }
            return (FileKind(identifier: "", name: ""), false)
        case .special, nil:
            switch KindKey.SpecialKind(rawValue: key.low) ?? .other {
            case .document: return (FileKind(identifier: "", name: "Document"), false)
            case .unixExecutable: return (describe(.unixExecutable), false)
            case .symlink: return (describe(.symbolicLink), false)
            case .package: return (describe(.package), true)
            case .fifo: return (FileKind(identifier: "", name: "Named Pipe"), false)
            case .socket: return (FileKind(identifier: "", name: "Socket"), false)
            case .characterDevice: return (FileKind(identifier: "", name: "Character Device"), false)
            case .blockDevice: return (FileKind(identifier: "", name: "Block Device"), false)
            case .other: return (FileKind(identifier: "", name: "Other"), false)
            }
        }
    }

    /// Deterministic kind table: the folder kind first, then the distinct
    /// kinds sorted by (identifier, name). Returns the table and a map from
    /// slot to final index.
    func finalTable() -> (kinds: [FileKind], remap: [UInt16]) {
        lock.lock()
        defer { lock.unlock() }
        let folder = slots[Self.folderSlot]!
        let others = Set(slots.filter { $0.key != Self.folderSlot }.map(\.value)).subtracting([folder])
        let sorted = others.sorted { ($0.identifier, $0.name) < ($1.identifier, $1.name) }
        var kinds = [folder] + sorted
        if kinds.count > Int(UInt16.max) + 1 { kinds = Array(kinds.prefix(Int(UInt16.max) + 1)) }
        var index: [FileKind: UInt16] = [:]
        for (i, kind) in kinds.enumerated() { index[kind] = UInt16(i) }
        var remap = [UInt16](repeating: 0, count: Int(nextSlot))
        for (slot, kind) in slots { remap[Int(slot)] = index[kind] ?? 0 }
        return (kinds, remap)
    }
}
