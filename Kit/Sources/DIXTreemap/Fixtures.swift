//
//  Fixtures.swift
//  DIXTreemap
//
//  Builds Snapshots in memory: from a nested description (tests) or as a
//  deterministic synthetic folder tree (offline rendering without a scan).
//  Not a scanner: nothing here touches the file system.
//
//  GPL v3
//

import DIXCore
import Foundation

public enum FixtureItem: Sendable {
    case file(String, size: UInt64, logical: UInt64? = nil, kind: String, flags: NodeFlags = [])
    case folder(String, [FixtureItem], flags: NodeFlags = [], kind: String? = nil)

    var name: String {
        switch self {
        case .file(let n, _, _, _, _), .folder(let n, _, _, _): return n
        }
    }
}

public enum SnapshotBuilder {
    /// Flattens a description into a valid Snapshot: breadth first, children
    /// contiguous and sorted by allocated size (descending, then name).
    public static func build(_ root: FixtureItem, rootPath: String = "/fixture",
                             volume: VolumeInfo? = nil) -> Snapshot {
        struct Flat {
            var name: [UInt8]; var alloc: UInt64; var logical: UInt64; var kind: Int; var flags: NodeFlags
            var children: [Int]
        }
        var flats: [Flat] = []
        var kindIndex: [String: Int] = ["Folder": 0]
        var kinds = [FileKind(identifier: "public.folder", name: "Folder")]
        func kindFor(_ name: String) -> Int {
            if let k = kindIndex[name] { return k }
            kinds.append(FileKind(identifier: "", name: name))
            kindIndex[name] = kinds.count - 1
            return kinds.count - 1
        }
        // recursive flatten into a temporary tree (depth of fixtures is small)
        func add(_ item: FixtureItem) -> Int {
            switch item {
            case let .file(name, size, logical, kind, flags):
                flats.append(Flat(name: Array(name.utf8), alloc: size, logical: logical ?? size,
                                  kind: kindFor(kind), flags: flags.subtracting(.directory), children: []))
                return flats.count - 1
            case let .folder(name, items, flags, kind):
                let me = flats.count
                var f: NodeFlags = flags
                f.insert(.directory)
                flats.append(Flat(name: Array(name.utf8), alloc: 0, logical: 0,
                                  kind: kind.map(kindFor) ?? 0, flags: f, children: []))
                var kids: [Int] = []
                for it in items { kids.append(add(it)) }
                var a: UInt64 = 0, l: UInt64 = 0
                for k in kids { a += flats[k].alloc; l += flats[k].logical }
                kids.sort { x, y in
                    flats[x].alloc != flats[y].alloc ? flats[x].alloc > flats[y].alloc
                        : flats[x].name.lexicographicallyPrecedes(flats[y].name)
                }
                flats[me].alloc = a
                flats[me].logical = l
                flats[me].children = kids
                return me
            }
        }
        let rootTemp = add(root)

        // breadth-first numbering
        var order: [Int] = [rootTemp]
        var newIndex = [Int](repeating: 0, count: flats.count)
        var head = 0
        while head < order.count {
            let t = order[head]
            newIndex[t] = head
            order.append(contentsOf: flats[t].children)
            head += 1
        }
        let n = order.count
        var parent = [UInt32](repeating: 0, count: n), firstChild = [UInt32](repeating: 0, count: n)
        var childCount = [UInt32](repeating: 0, count: n)
        var alloc = [UInt64](repeating: 0, count: n), logical = [UInt64](repeating: 0, count: n)
        var nameOffset = [UInt32](repeating: 0, count: n), nameLength = [UInt16](repeating: 0, count: n)
        var kindIdx = [UInt16](repeating: 0, count: n), flags = [NodeFlags](repeating: [], count: n)
        var nameBytes: [UInt8] = []
        for (i, t) in order.enumerated() {
            let f = flats[t]
            alloc[i] = f.alloc
            logical[i] = f.logical
            nameOffset[i] = UInt32(nameBytes.count)
            nameLength[i] = UInt16(min(f.name.count, Int(UInt16.max)))
            nameBytes.append(contentsOf: f.name.prefix(Int(UInt16.max)))
            kindIdx[i] = UInt16(f.kind)
            flags[i] = f.flags
            childCount[i] = UInt32(f.children.count)
            firstChild[i] = f.children.isEmpty ? 0 : UInt32(newIndex[f.children[0]])
            for c in f.children { parent[newIndex[c]] = UInt32(i) }
        }
        return Snapshot(rootPath: rootPath, scanDate: Date(timeIntervalSince1970: 0), volume: volume,
                        parent: parent, firstChild: firstChild, childCount: childCount,
                        allocatedSize: alloc, logicalSize: logical, nameOffset: nameOffset, nameLength: nameLength,
                        kindIndex: kindIdx, flags: flags, nameBytes: nameBytes, kinds: kinds)
    }
}

/// Deterministic pseudo-random folder trees that look like real disks: a few
/// huge media files, source trees, node_modules-style folders with thousands
/// of tiny files, app bundles, caches, and a cloud folder of placeholders.
public enum SyntheticSnapshot {
    public static func make(seed: UInt64 = 1, scale: Int = 1) -> Snapshot {
        var rng = SplitMix64(seed: seed)
        let kinds: [(String, Double)] = [   // name, log10 mean size
            ("JPEG image", 6.3), ("PNG image", 4.6), ("Swift Source", 3.9), ("JavaScript script", 3.6),
            ("MPEG-4 movie", 8.4), ("PDF document", 5.8), ("Plain text", 3.2), ("Unix Executable", 6.5),
            ("JSON", 3.4), ("Mach-O Dylib", 6.9), ("ZIP archive", 7.4), ("Disk Image", 9.0),
            ("SQLite DB", 6.6), ("Header", 3.5), ("MP3 audio", 6.8), ("Log", 4.5), ("Font", 5.2),
            ("Python script", 3.6), ("HTML", 4.0), ("Markdown", 3.3), ("CSS", 3.7), ("XML", 3.8),
        ]
        func fileSize(_ meanLog: Double, _ spread: Double = 0.55) -> UInt64 {
            let v = pow(10, meanLog + rng.normal() * spread)
            let blocks = max(1, UInt64(v / 4096) + 1)
            return blocks * 4096
        }
        func pickKind(_ bias: [Int]) -> Int {
            rng.unit() < 0.75 ? bias[rng.int(bias.count)] : rng.int(kinds.count)
        }
        func files(_ count: Int, _ bias: [Int], sizeShift: Double = 0) -> [FixtureItem] {
            (0 ..< count).map { i in
                let k = pickKind(bias)
                return .file("f\(i).\(k)", size: fileSize(kinds[k].1 + sizeShift), kind: kinds[k].0)
            }
        }
        func tree(_ depth: Int, _ bias: [Int], fanout: Int, filesPer: Int, tiny: Bool) -> FixtureItem {
            var items = files(max(1, Int(Double(filesPer) * (0.3 + rng.unit() * 1.4))), bias,
                              sizeShift: tiny ? -1.0 : 0)
            if depth > 0 {
                let n = max(1, Int(Double(fanout) * (0.4 + rng.unit())))
                for i in 0 ..< n {
                    var sub = tree(depth - 1, bias, fanout: fanout, filesPer: filesPer, tiny: tiny)
                    if case .folder(_, let it, let fl, let k) = sub { sub = .folder("d\(i)", it, flags: fl, kind: k) }
                    items.append(sub)
                }
            }
            return .folder("dir", items)
        }
        func named(_ name: String, _ item: FixtureItem) -> FixtureItem {
            if case .folder(_, let it, let fl, let k) = item { return .folder(name, it, flags: fl, kind: k) }
            return item
        }
        var top: [FixtureItem] = []
        top.append(.folder("Movies", files(6 * scale, [4]) + files(3, [10])))
        top.append(named("Photos", tree(2, [0, 1], fanout: 6, filesPer: 60 * scale, tiny: false)))
        top.append(named("Code", tree(4, [2, 13, 8, 6], fanout: 5, filesPer: 18 * scale, tiny: true)))
        top.append(named("node_modules", tree(3, [3, 8, 19, 6], fanout: 9, filesPer: 25 * scale, tiny: true)))
        top.append(named("Music", tree(2, [14], fanout: 5, filesPer: 12, tiny: false)))
        top.append(.folder("Disk Images", files(3, [11])))
        top.append(named("Caches", tree(2, [12, 15, 6], fanout: 7, filesPer: 40 * scale, tiny: true)))
        // two app bundles
        for a in 0 ..< 2 {
            let app = tree(3, [9, 7, 16, 1, 21], fanout: 4, filesPer: 20, tiny: false)
            if case .folder(_, let it, _, _) = app {
                top.append(.folder("App\(a).app", it, flags: [.package], kind: "Application"))
            }
        }
        // a cloud-synced folder: placeholders occupy ~0 on disk but have a logical size
        let cloud: [FixtureItem] = (0 ..< 40 * scale).map { i in
            let k = pickKind([0, 5, 10])
            let logical = fileSize(kinds[k].1)
            let isPlaceholder = i % 5 != 0
            return .file("c\(i)", size: isPlaceholder ? 0 : logical, logical: logical, kind: kinds[k].0,
                         flags: isPlaceholder ? [.cloudPlaceholder] : [])
        }
        top.append(.folder("Cloud Drive", cloud))
        top.append(.folder("Empty", []))
        top.append(.folder("zeros", (0 ..< 20).map { .file("z\($0)", size: 0, kind: "Plain text") }))
        return SnapshotBuilder.build(.folder("synthetic", top), rootPath: "/synthetic",
                                     volume: VolumeInfo(name: "Synthetic", mountPath: "/",
                                                        totalCapacity: 500_000_000_000, availableCapacity: 120_000_000_000))
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    mutating func normal() -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
