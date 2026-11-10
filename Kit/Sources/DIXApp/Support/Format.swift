//
//  Format.swift
//  DIXApp
//
//  Number and size formatting, as the original app did it (FileSizeFormatter:
//  powers of 1000, "Bytes"/"kB" as integers like the Finder, one decimal from MB up).
//
//  GPL v3
//

import Foundation

public enum Format {
    private static let units = ["Bytes", "kB", "MB", "GB", "TB", "PB"]

    private static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    private static let count: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// "0 Bytes", "812 kB", "1.2 MB", "3,402.5 GB"
    public static func size(_ bytes: UInt64) -> String {
        var value = Double(bytes)
        var unit = 0
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit <= 1 { return "\(Int(value.rounded())) \(units[unit])" }
        return (decimal.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)) + " " + units[unit]
    }

    /// "1,204"
    public static func count(_ n: Int) -> String {
        count.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "0:07", "12:03", "1:02:03"
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
