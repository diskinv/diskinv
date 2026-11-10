//
//  ScanEstimate.swift
//  DIXApp
//
//  The scan progress panel's text, and the time-left estimate. A percentage
//  needs the total number of items up front: known for a volume's root (its
//  used inode count, from DIXScan) and for any folder scanned before (the
//  count remembered from the last completed scan). Otherwise the panel shows
//  live counts and an animated bar.
//
//    Scanning “b” — 42% · about 20 s left
//    a/cowboy/server/node_modules
//    184,203 items · 6.1 GB · 0:07
//
//  Ported from ScanEstimate in FileSystemDoc.swift (branch swift-overhaul-review).
//
//  GPL v3
//

import Foundation
import DIXScan

/// Remembers how many items each folder had when it was last scanned.
public final class ScanCountMemory {
    public static let shared = ScanCountMemory(defaults: .standard)
    static let defaultsKey = "ScanItemCounts"
    static let maxRememberedFolders = 100
    let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func count(forFolder path: String) -> Int? {
        guard let entry = defaults.dictionary(forKey: Self.defaultsKey)?[path] as? [String: Any],
              let count = entry["count"] as? Int, count > 0 else { return nil }
        return count
    }

    public func record(_ count: Int, forFolder path: String, date: Date = Date()) {
        guard count > 0 else { return }
        var all = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        all[path] = ["count": count, "date": date]
        while all.count > Self.maxRememberedFolders {
            func date(_ value: Any) -> Date { ((value as? [String: Any])?["date"] as? Date) ?? .distantPast }
            guard let oldest = all.min(by: { date($0.value) < date($1.value) }) else { break }
            all.removeValue(forKey: oldest.key)
        }
        defaults.set(all, forKey: Self.defaultsKey)
    }
}

public enum ScanEstimate {
    /// items the scan of `path` will find, if knowable: the volume's used inode
    /// count for a volume root, else the count remembered from the last scan
    public static func expectedItemCount(forFolder path: String, memory: ScanCountMemory = .shared) -> Int? {
        if let n = DIXScan.Scanner.expectedItemCount(forRoot: path), n > 0 { return n }
        return memory.count(forFolder: path)
    }

    /// smoothed scan rate, so the time left doesn't jump around
    public struct Rate: Sendable {
        var lastElapsed: TimeInterval = 0
        var lastItems = 0
        public private(set) var itemsPerSecond: Double = 0
        public init() {}

        mutating func update(items: Int, elapsed: TimeInterval) {
            guard elapsed - lastElapsed >= 0.5 else { return }
            let rate = Double(items - lastItems) / (elapsed - lastElapsed)
            itemsPerSecond = itemsPerSecond == 0 ? rate : 0.7 * itemsPerSecond + 0.3 * rate
            lastElapsed = elapsed
            lastItems = items
        }
    }

    public struct Status: Equatable, Sendable {
        public var title: String
        public var folder: String
        public var detail: String
        /// 0...0.99 when the total is known, else nil (animated bar)
        public var fraction: Double?
    }

    /// the panel text for a progress reading
    public static func status(rootPath: String, displayName: String, items: Int, bytes: UInt64,
                              currentPath: String, expectedItems: Int?, elapsed: TimeInterval,
                              rate: inout Rate) -> Status {
        rate.update(items: items, elapsed: elapsed)

        var title = "Scanning “\(displayName)”"
        var fraction: Double?
        if let expected = expectedItems, expected > 0 {
            let value = min(Double(items) / Double(expected), 0.99)
            fraction = value
            title += " — \(Int(value * 100))%"
            if elapsed >= 2, value >= 0.03, rate.itemsPerSecond > 0 {
                if items >= expected {
                    title += " · almost done"
                } else {
                    title += " · " + timeLeft(Double(expected - items) / rate.itemsPerSecond)
                }
            }
        }

        // the folder being read, relative to the scanned one
        var folder = currentPath
        if folder == rootPath {
            folder = ""
        } else if folder.hasPrefix(rootPath + "/") || (rootPath == "/" && folder.hasPrefix("/")) {
            folder = String(folder.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1))
        } else {
            folder = (folder as NSString).abbreviatingWithTildeInPath
        }

        let detail = "\(Format.count(items)) items · \(Format.size(bytes)) · \(Format.elapsed(elapsed))"
        return Status(title: title, folder: folder, detail: detail, fraction: fraction)
    }

    public static func timeLeft(_ seconds: Double) -> String {
        if seconds < 10 { return "a few seconds left" }
        if seconds < 60 { return "about \(max(10, Int((seconds / 5).rounded()) * 5)) s left" }
        return "about \(Int((seconds / 60).rounded())) min left"
    }
}
