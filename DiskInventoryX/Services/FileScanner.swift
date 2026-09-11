import Foundation
import UniformTypeIdentifiers

enum FileScannerError: LocalizedError {
  case notDirectory(String)
  case cannotEnumerate(String)

  var errorDescription: String? {
    switch self {
    case .notDirectory(let path): "Not a folder: \(path)"
    case .cannotEnumerate(let path): "The folder could not be read: \(path)"
    }
  }
}

enum FileScanner {
  private static let resourceKeys: Set<URLResourceKey> = [
    .contentTypeKey,
    .fileSizeKey,
    .isAliasFileKey,
    .isDirectoryKey,
    .isPackageKey,
    .isSymbolicLinkKey,
    .nameKey,
    .totalFileAllocatedSizeKey,
  ]

  static func scan(
    url originalURL: URL,
    options: ScanOptions,
    progress: @escaping @Sendable (ScanProgress) -> Void
  ) throws -> ScanResult {
    let url = originalURL.standardizedFileURL
    let issueLog = IssueLog()
    var registry = KindRegistry()
    let rootValues = try url.resourceValues(forKeys: resourceKeys)

    guard rootValues.isDirectory == true else {
      throw FileScannerError.notDirectory(url.path)
    }

    let rootName = rootValues.name.flatMap { $0.isEmpty ? nil : $0 } ?? url.path
    let root = NodeBuilder(
      path: url.path,
      name: rootName,
      isPackage: rootValues.isPackage ?? false,
      kindID: FileKind.folderID
    )
    var stack = [root]
    var filesScanned = 0
    var foldersScanned = 1
    var entriesScanned = 0

    guard
      let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: Array(resourceKeys),
        options: [],
        errorHandler: { failedURL, error in
          issueLog.record(path: failedURL.path, error: error)
          return true
        }
      )
    else {
      throw FileScannerError.cannotEnumerate(url.path)
    }

    while let entryURL = enumerator.nextObject() as? URL {
      try Task.checkCancellation()
      entriesScanned += 1

      let level = max(1, enumerator.level)
      while stack.count > level {
        closeLastDirectory(in: &stack)
      }

      do {
        let values = try entryURL.resourceValues(forKeys: resourceKeys)
        let isLink = values.isSymbolicLink == true || values.isAliasFile == true
        let isDirectory = values.isDirectory == true && !isLink
        let isPackage = values.isPackage ?? false
        let name = values.name ?? entryURL.lastPathComponent
        let kindID = registry.kindID(
          for: values.contentType,
          pathExtension: entryURL.pathExtension,
          isDirectory: isDirectory,
          isPackage: isPackage
        )

        if isDirectory {
          foldersScanned += 1
          stack.append(
            NodeBuilder(
              path: entryURL.path,
              name: name,
              isPackage: isPackage,
              kindID: kindID
            ))
        } else {
          if isLink {
            enumerator.skipDescendants()
          }
          filesScanned += 1
          stack.last?.append(
            FileNode(
              path: entryURL.path,
              name: name,
              isDirectory: false,
              isPackage: false,
              size: fileSize(from: values, mode: options.sizeMode),
              kindID: kindID
            ))
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        enumerator.skipDescendants()
        issueLog.record(path: entryURL.path, error: error)
        filesScanned += 1
        stack.last?.append(
          FileNode(
            path: entryURL.path,
            name: entryURL.lastPathComponent,
            isDirectory: false,
            size: 0,
            kindID: FileKind.documentID
          ))
      }

      if entriesScanned.isMultiple(of: 256) {
        progress(
          ScanProgress(
            currentFolder: stack.last?.name ?? rootName,
            filesScanned: filesScanned,
            foldersScanned: foldersScanned
          ))
      }
    }

    while stack.count > 1 {
      closeLastDirectory(in: &stack)
    }

    let rootNode = root.finish()
    progress(
      ScanProgress(
        currentFolder: rootName,
        filesScanned: filesScanned,
        foldersScanned: foldersScanned
      ))

    return ScanResult(
      sizeMode: options.sizeMode,
      root: rootNode,
      kinds: registry.kinds,
      expandedStatistics: statistics(for: rootNode, collapsePackages: false),
      collapsedPackageStatistics: statistics(for: rootNode, collapsePackages: true),
      filesScanned: filesScanned,
      foldersScanned: foldersScanned,
      issues: issueLog.issues,
      issueCount: issueLog.count,
      volumeSpace: volumeSpace(for: url)
    )
  }

  private static func closeLastDirectory(in stack: inout [NodeBuilder]) {
    guard stack.count > 1 else { return }
    let child = stack.removeLast().finish()
    stack.last?.append(child)
  }

  private static func fileSize(from values: URLResourceValues, mode: FileSizeMode) -> UInt64 {
    let value: Int?
    switch mode {
    case .logical:
      value = values.fileSize
    case .allocated:
      value = values.totalFileAllocatedSize ?? values.fileSize
    }
    return UInt64(max(0, value ?? 0))
  }

  private static func statistics(for root: FileNode, collapsePackages: Bool) -> [FileKindStatistic]
  {
    var totals: [UInt32: (count: Int, size: UInt64)] = [:]

    func visit(_ node: FileNode) {
      if !node.isDirectory || collapsePackages && node.isPackage {
        let old = totals[node.kindID] ?? (0, 0)
        totals[node.kindID] = (old.count + 1, old.size.saturatingAdding(node.size))
        return
      }
      for child in node.children {
        visit(child)
      }
    }

    visit(root)
    return totals.map {
      FileKindStatistic(kindID: $0.key, count: $0.value.count, totalSize: $0.value.size)
    }.sorted { lhs, rhs in
      lhs.totalSize == rhs.totalSize ? lhs.kindID < rhs.kindID : lhs.totalSize > rhs.totalSize
    }
  }

  private static func volumeSpace(for url: URL) -> VolumeSpace? {
    guard
      let values = try? url.resourceValues(forKeys: [
        .isVolumeKey,
        .volumeAvailableCapacityKey,
        .volumeTotalCapacityKey,
      ]), values.isVolume == true,
      let total = values.volumeTotalCapacity,
      let available = values.volumeAvailableCapacity
    else {
      return nil
    }

    return VolumeSpace(
      total: UInt64(max(0, total)),
      available: UInt64(max(0, available))
    )
  }
}

private final class NodeBuilder {
  let path: String
  let name: String
  let isPackage: Bool
  let kindID: UInt32
  private var size: UInt64 = 0
  private var children: [FileNode] = []

  init(path: String, name: String, isPackage: Bool, kindID: UInt32) {
    self.path = path
    self.name = name
    self.isPackage = isPackage
    self.kindID = kindID
  }

  func append(_ child: FileNode) {
    children.append(child)
    size = size.saturatingAdding(child.size)
  }

  func finish() -> FileNode {
    children.sort {
      $0.size == $1.size
        ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
        : $0.size > $1.size
    }
    return FileNode(
      path: path,
      name: name,
      isDirectory: true,
      isPackage: isPackage,
      size: size,
      kindID: kindID,
      children: children
    )
  }
}

private final class IssueLog {
  private(set) var count = 0
  private(set) var issues: [ScanIssue] = []

  func record(path: String, error: Error) {
    count += 1
    if issues.count < 500 {
      issues.append(ScanIssue(path: path, message: error.localizedDescription))
    }
  }
}

private struct KindRegistry {
  private var idsByType: [String: UInt32] = [:]
  private(set) var kinds = [
    FileKind(id: FileKind.folderID, name: "Folder"),
    FileKind(id: FileKind.documentID, name: "Document"),
    FileKind(id: FileKind.freeSpaceID, name: "Free Space"),
    FileKind(id: FileKind.otherSpaceID, name: "Other Space"),
  ]

  mutating func kindID(
    for contentType: UTType?,
    pathExtension: String,
    isDirectory: Bool,
    isPackage: Bool
  ) -> UInt32 {
    if isDirectory && !isPackage { return FileKind.folderID }

    let normalizedExtension = pathExtension.lowercased()
    let key = contentType?.identifier ?? "extension:\(normalizedExtension)"
    if let existing = idsByType[key] { return existing }

    let name: String
    if let contentType, !contentType.identifier.hasPrefix("dyn.") {
      name = contentType.localizedDescription ?? contentType.identifier
    } else if normalizedExtension.isEmpty {
      return FileKind.documentID
    } else {
      name = ".\(normalizedExtension.uppercased()) file"
    }

    if let existing = kinds.first(where: { $0.name == name })?.id {
      idsByType[key] = existing
      return existing
    }

    let id = UInt32(kinds.count)
    kinds.append(FileKind(id: id, name: name))
    idsByType[key] = id
    return id
  }
}
