import Foundation

struct FileKind: Identifiable, Hashable, Sendable {
  static let folderID: UInt32 = 0
  static let documentID: UInt32 = 1
  static let freeSpaceID: UInt32 = 2
  static let otherSpaceID: UInt32 = 3

  let id: UInt32
  let name: String
}

struct FileKindStatistic: Identifiable, Hashable, Sendable {
  var id: UInt32 { kindID }
  let kindID: UInt32
  let count: Int
  let totalSize: UInt64
}

enum FileSizeMode: String, CaseIterable, Identifiable, Sendable {
  case logical
  case allocated

  var id: Self { self }

  var label: String {
    switch self {
    case .logical: "Logical"
    case .allocated: "On disk"
    }
  }
}

struct ScanOptions: Sendable {
  static let maximumWorkerCount = 64

  let sizeMode: FileSizeMode
  let workerCount: Int

  init(sizeMode: FileSizeMode, workerCount: Int = 0) {
    self.sizeMode = sizeMode
    self.workerCount = workerCount
  }

  var resolvedWorkerCount: Int {
    Self.resolveWorkerCount(
      workerCount, activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount)
  }

  static func resolveWorkerCount(_ requested: Int, activeProcessorCount: Int) -> Int {
    if requested == 0 {
      return max(1, activeProcessorCount - 1)
    }
    return min(max(1, requested), maximumWorkerCount)
  }
}

struct ScanProgress: Equatable, Sendable {
  let currentFolder: String
  let filesScanned: Int
  let foldersScanned: Int
}

struct ScanIssue: Identifiable, Hashable, Sendable {
  var id: String { path + "\u{0}" + message }
  let path: String
  let message: String
}

struct VolumeSpace: Sendable {
  let total: UInt64
  let available: UInt64
}

struct ScanResult: Sendable {
  let sizeMode: FileSizeMode
  let root: FileNode
  let kinds: [FileKind]
  let expandedStatistics: [FileKindStatistic]
  let collapsedPackageStatistics: [FileKindStatistic]
  let filesScanned: Int
  let foldersScanned: Int
  let issues: [ScanIssue]
  let issueCount: Int
  let volumeSpace: VolumeSpace?
}
