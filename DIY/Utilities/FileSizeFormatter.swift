//
//  FileSizeFormatter.swift
//  DiskInventoryX
//
//  Human-readable file size formatting
//

import Foundation

enum FileSizeFormatter {
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter
    }()

    static func string(from bytes: UInt64) -> String {
        byteCountFormatter.string(fromByteCount: Int64(bytes))
    }

    static func string(from bytes: Int64) -> String {
        byteCountFormatter.string(fromByteCount: bytes)
    }

    /// Returns a shorter format for compact display
    static func shortString(from bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
