import Foundation

enum FileNodeType: String, Sendable {
  case regular
  case otherSpace
  case freeSpace
}

struct FileNode: Identifiable, Hashable, Sendable {
  let id: String
  let path: String
  let name: String
  let isDirectory: Bool
  let isPackage: Bool
  let size: UInt64
  let kindID: UInt32
  let type: FileNodeType
  let children: [FileNode]

  init(
    id: String? = nil,
    path: String,
    name: String,
    isDirectory: Bool,
    isPackage: Bool = false,
    size: UInt64,
    kindID: UInt32,
    type: FileNodeType = .regular,
    children: [FileNode] = []
  ) {
    self.id = id ?? path
    self.path = path
    self.name = name
    self.isDirectory = isDirectory
    self.isPackage = isPackage
    self.size = size
    self.kindID = kindID
    self.type = type
    self.children = children
  }

  static func == (lhs: FileNode, rhs: FileNode) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  var url: URL? {
    type == .regular ? URL(fileURLWithPath: path) : nil
  }

  var isSpecialItem: Bool {
    type != .regular
  }

  func node(withID nodeID: String) -> FileNode? {
    if id == nodeID { return self }
    for child in children {
      if let match = child.node(withID: nodeID) { return match }
    }
    return nil
  }

  func visibleEntries(showPackageContents: Bool, kindID wantedKindID: UInt32? = nil) -> [FileNode] {
    var result: [FileNode] = []
    collectVisibleEntries(
      showPackageContents: showPackageContents,
      kindID: wantedKindID,
      into: &result
    )
    return result
  }

  func isDescendant(of ancestor: FileNode) -> Bool {
    guard type == .regular, ancestor.type == .regular, id != ancestor.id else { return false }
    let prefix = ancestor.path.hasSuffix("/") ? ancestor.path : ancestor.path + "/"
    return path.hasPrefix(prefix)
  }

  func replacingChildren(_ newChildren: [FileNode]) -> FileNode {
    FileNode(
      id: id,
      path: path,
      name: name,
      isDirectory: isDirectory,
      isPackage: isPackage,
      size: newChildren.reduce(0) { $0.saturatingAdding($1.size) },
      kindID: kindID,
      type: type,
      children: newChildren
    )
  }

  private func collectVisibleEntries(
    showPackageContents: Bool,
    kindID wantedKindID: UInt32?,
    into result: inout [FileNode]
  ) {
    let actsAsLeaf = !isDirectory || isPackage && !showPackageContents || isSpecialItem
    if actsAsLeaf {
      if wantedKindID == nil || kindID == wantedKindID {
        result.append(self)
      }
      return
    }

    for child in children {
      child.collectVisibleEntries(
        showPackageContents: showPackageContents,
        kindID: wantedKindID,
        into: &result
      )
    }
  }
}

extension UInt64 {
  func saturatingAdding(_ other: UInt64) -> UInt64 {
    let (sum, overflow) = addingReportingOverflow(other)
    return overflow ? .max : sum
  }
}
