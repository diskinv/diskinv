import Foundation

enum FileSizeFormatter {
  static func string(from bytes: UInt64) -> String {
    ByteCountFormatter.string(
      fromByteCount: Int64(clamping: bytes),
      countStyle: .file
    )
  }
}
