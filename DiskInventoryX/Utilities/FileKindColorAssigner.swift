import SwiftUI

enum FileKindColorAssigner {
  private static let palette = [
    Color(red: 0.91, green: 0.40, blue: 0.33),
    Color(red: 0.95, green: 0.62, blue: 0.27),
    Color(red: 0.86, green: 0.74, blue: 0.25),
    Color(red: 0.57, green: 0.70, blue: 0.28),
    Color(red: 0.20, green: 0.64, blue: 0.45),
    Color(red: 0.16, green: 0.62, blue: 0.61),
    Color(red: 0.20, green: 0.65, blue: 0.82),
    Color(red: 0.29, green: 0.52, blue: 0.86),
    Color(red: 0.39, green: 0.42, blue: 0.78),
    Color(red: 0.52, green: 0.36, blue: 0.76),
    Color(red: 0.69, green: 0.34, blue: 0.70),
    Color(red: 0.82, green: 0.33, blue: 0.56),
    Color(red: 0.89, green: 0.36, blue: 0.46),
    Color(red: 0.67, green: 0.48, blue: 0.35),
    Color(red: 0.43, green: 0.55, blue: 0.63),
    Color(red: 0.46, green: 0.63, blue: 0.50),
  ]

  static func color(for kindName: String) -> Color {
    switch kindName {
    case "Free Space": return Color(white: 0.72)
    case "Other Space": return Color(white: 0.48)
    case "Folder": return Color(red: 0.39, green: 0.42, blue: 0.78)
    default:
      var hash: UInt64 = 14_695_981_039_346_656_037
      for byte in kindName.utf8 {
        hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
      }
      return palette[Int(hash % UInt64(palette.count))]
    }
  }
}
