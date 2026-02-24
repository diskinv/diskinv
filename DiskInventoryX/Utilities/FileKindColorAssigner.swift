//
//  FileKindColorAssigner.swift
//  DiskInventoryX
//
//  Assigns consistent colors to file kinds
//

import SwiftUI

class FileKindColorAssigner {
    private var assignedColors: [String: Color] = [:]
    private var nextColorIndex = 0

    // Color palette - vibrant colors that work well in treemaps
    private let palette: [Color] = [
        Color(red: 0.40, green: 0.60, blue: 1.00),  // Blue
        Color(red: 1.00, green: 0.55, blue: 0.35),  // Orange
        Color(red: 0.45, green: 0.80, blue: 0.45),  // Green
        Color(red: 0.90, green: 0.45, blue: 0.65),  // Pink
        Color(red: 0.70, green: 0.50, blue: 0.90),  // Purple
        Color(red: 0.95, green: 0.75, blue: 0.30),  // Yellow
        Color(red: 0.40, green: 0.80, blue: 0.80),  // Cyan
        Color(red: 0.80, green: 0.55, blue: 0.45),  // Brown
        Color(red: 0.65, green: 0.70, blue: 0.40),  // Olive
        Color(red: 0.85, green: 0.50, blue: 0.50),  // Coral
        Color(red: 0.55, green: 0.65, blue: 0.75),  // Steel Blue
        Color(red: 0.75, green: 0.60, blue: 0.70),  // Mauve
        Color(red: 0.60, green: 0.75, blue: 0.55),  // Sage
        Color(red: 0.90, green: 0.65, blue: 0.50),  // Peach
        Color(red: 0.50, green: 0.70, blue: 0.65),  // Teal
        Color(red: 0.80, green: 0.70, blue: 0.55),  // Tan
    ]

    // Predefined colors for common types
    private let predefinedColors: [String: Color] = [
        "Folder": Color(red: 0.60, green: 0.60, blue: 0.60),
        "Free Space": Color(red: 0.85, green: 0.85, blue: 0.85),
        "Other Space": Color(red: 0.70, green: 0.70, blue: 0.70),
        "Application": Color(red: 0.40, green: 0.60, blue: 1.00),
        "JPEG image": Color(red: 0.45, green: 0.80, blue: 0.45),
        "PNG image": Color(red: 0.50, green: 0.75, blue: 0.50),
        "HEIC image": Color(red: 0.55, green: 0.70, blue: 0.55),
        "GIF image": Color(red: 0.60, green: 0.65, blue: 0.60),
        "PDF document": Color(red: 0.90, green: 0.45, blue: 0.45),
        "MP3 audio": Color(red: 0.70, green: 0.50, blue: 0.90),
        "MPEG-4 audio": Color(red: 0.65, green: 0.55, blue: 0.85),
        "MPEG-4 movie": Color(red: 0.90, green: 0.55, blue: 0.35),
        "QuickTime movie": Color(red: 0.85, green: 0.60, blue: 0.40),
        "Zip archive": Color(red: 0.80, green: 0.55, blue: 0.45),
        "Disk image": Color(red: 0.75, green: 0.60, blue: 0.50),
    ]

    func color(for kindName: String) -> Color {
        // Check predefined colors first
        if let predefined = predefinedColors[kindName] {
            return predefined
        }

        // Check if already assigned
        if let existing = assignedColors[kindName] {
            return existing
        }

        // Assign next color from palette
        let color = palette[nextColorIndex % palette.count]
        assignedColors[kindName] = color
        nextColorIndex += 1
        return color
    }

    func reset() {
        assignedColors.removeAll()
        nextColorIndex = 0
    }
}
