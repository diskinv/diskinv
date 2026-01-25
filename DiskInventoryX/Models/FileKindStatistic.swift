//
//  FileKindStatistic.swift
//  DiskInventoryX
//
//  Statistics for a file type/kind
//

import SwiftUI

struct FileKindStatistic: Identifiable, Hashable {
    let id = UUID()
    let kindName: String
    let count: Int
    let totalSize: UInt64
    let color: Color

    var formattedSize: String {
        FileSizeFormatter.string(from: totalSize)
    }

    var formattedCount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}
