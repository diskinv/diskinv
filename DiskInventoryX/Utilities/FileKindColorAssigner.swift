import SwiftUI

enum FileKindColorAssigner {
  static func color(for kindName: String) -> Color {
    switch kindName {
    case "Free Space": return Color(white: 0.72)
    case "Other Space": return Color(white: 0.48)
    case "Folder": return Color(red: 0.25, green: 0.45, blue: 0.95)
    default:
      var hash: UInt64 = 14_695_981_039_346_656_037
      for byte in kindName.utf8 {
        hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
      }
      return Color(
        hue: Double(hash % 360) / 360,
        saturation: 0.88,
        brightness: 0.86
      )
    }
  }
}
