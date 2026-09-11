import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
  @Published private(set) var rootNode: FileNode?
  @Published private(set) var zoomedNode: FileNode?
  @Published var selectedNode: FileNode?
  @Published private(set) var zoomStack: [FileNode] = []

  @Published private(set) var isScanning = false
  @Published private(set) var scanProgress: ScanProgress?
  @Published var errorMessage: String?

  @Published private(set) var kindStatistics: [FileKindStatistic] = []
  @Published var selectedKindID: UInt32? {
    didSet { rebuildFilteredNodes() }
  }
  @Published private(set) var filteredNodes: [FileNode] = []
  @Published var showsScanIssues = false
  @Published var trashCandidate: FileNode?
  @Published private(set) var treeRevision = UUID()

  @AppStorage("sizeMode") var sizeModeRaw = FileSizeMode.logical.rawValue
  @AppStorage("showPackageContents") var showPackageContents = false {
    didSet { applyPresentationOptions() }
  }
  @AppStorage("showFreeSpace") var showFreeSpace = true {
    didSet { applyPresentationOptions() }
  }
  @AppStorage("showOtherSpace") var showOtherSpace = true {
    didSet { applyPresentationOptions() }
  }

  private var result: ScanResult?
  private var kindsByID: [UInt32: FileKind] = [:]
  private var scanTask: Task<Void, Never>?
  private var filterTask: Task<Void, Never>?
  private var scanToken = UUID()
  private var filterToken = UUID()

  var displayRoot: FileNode? {
    zoomedNode ?? rootNode
  }

  var sizeMode: FileSizeMode {
    get { FileSizeMode(rawValue: sizeModeRaw) ?? .logical }
    set { sizeModeRaw = newValue.rawValue }
  }

  var scannedSizeMode: FileSizeMode? {
    result?.sizeMode
  }

  var scanIssues: [ScanIssue] {
    result?.issues ?? []
  }

  var scanIssueCount: Int {
    result?.issueCount ?? 0
  }

  var filesScanned: Int {
    result?.filesScanned ?? 0
  }

  var foldersScanned: Int {
    result?.foldersScanned ?? 0
  }

  func showOpenPanel() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select a folder to analyze"
    panel.prompt = "Scan"

    if panel.runModal() == .OK, let url = panel.url {
      startScan(url: url)
    }
  }

  func startScan(url: URL) {
    cancelScan()

    let token = UUID()
    scanToken = token
    isScanning = true
    scanProgress = ScanProgress(
      currentFolder: url.lastPathComponent,
      filesScanned: 0,
      foldersScanned: 1
    )
    errorMessage = nil
    result = nil
    rootNode = nil
    zoomedNode = nil
    selectedNode = nil
    zoomStack = []
    selectedKindID = nil
    kindStatistics = []
    filteredNodes = []

    let options = ScanOptions(sizeMode: sizeMode)
    scanTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      do {
        let result = try FileScanner.scan(url: url, options: options) { progress in
          Task { @MainActor in
            guard self.scanToken == token else { return }
            self.scanProgress = progress
          }
        }
        await self.finishScan(result, token: token)
      } catch is CancellationError {
        await self.finishCancellation(token: token)
      } catch {
        await self.finishScanError(error, token: token)
      }
    }
  }

  func cancelScan() {
    scanToken = UUID()
    scanTask?.cancel()
    scanTask = nil
    isScanning = false
    scanProgress = nil
  }

  func refresh() {
    guard let path = result?.root.path else { return }
    startScan(url: URL(fileURLWithPath: path))
  }

  func zoomIn() {
    guard let selectedNode,
      selectedNode.isDirectory,
      !selectedNode.isPackage || showPackageContents
    else { return }

    zoomStack.append(zoomedNode ?? rootNode ?? selectedNode)
    zoomedNode = selectedNode
    rebuildFilteredNodes()
  }

  func zoomOut() {
    guard let previous = zoomStack.popLast() else { return }
    zoomedNode = previous.id == rootNode?.id ? nil : previous
    rebuildFilteredNodes()
  }

  func zoomToRoot() {
    zoomedNode = nil
    zoomStack = []
    rebuildFilteredNodes()
  }

  func kindName(for id: UInt32) -> String {
    kindsByID[id]?.name ?? "Unknown"
  }

  func color(for kindID: UInt32) -> Color {
    FileKindColorAssigner.color(for: kindName(for: kindID))
  }

  func moveToTrash(_ node: FileNode) {
    guard let url = node.url, node.id != result?.root.id else { return }
    do {
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      refresh()
    } catch {
      errorMessage = "Could not move \"\(node.name)\" to the Trash. \(error.localizedDescription)"
    }
  }

  func confirmTrash() {
    guard let trashCandidate else { return }
    self.trashCandidate = nil
    moveToTrash(trashCandidate)
  }

  private func finishScan(_ newResult: ScanResult, token: UUID) {
    guard scanToken == token else { return }
    result = newResult
    kindsByID = Dictionary(uniqueKeysWithValues: newResult.kinds.map { ($0.id, $0) })
    isScanning = false
    scanProgress = nil
    scanTask = nil
    applyPresentationOptions()
  }

  private func finishCancellation(token: UUID) {
    guard scanToken == token else { return }
    isScanning = false
    scanProgress = nil
    scanTask = nil
  }

  private func finishScanError(_ error: Error, token: UUID) {
    guard scanToken == token else { return }
    isScanning = false
    scanProgress = nil
    scanTask = nil
    errorMessage = error.localizedDescription
  }

  private func applyPresentationOptions() {
    guard let result else { return }
    let priorSelectedID = selectedNode?.id
    let priorZoomedID = zoomedNode?.id
    var children = result.root.children
    var statistics =
      showPackageContents
      ? result.expandedStatistics
      : result.collapsedPackageStatistics

    if let volume = result.volumeSpace {
      let used = volume.total > volume.available ? volume.total - volume.available : 0
      let other = used > result.root.size ? used - result.root.size : 0

      if showOtherSpace, other > 0 {
        children.append(
          FileNode(
            id: result.root.id + "\u{0}other-space",
            path: result.root.path,
            name: "Other Space",
            isDirectory: false,
            size: other,
            kindID: FileKind.otherSpaceID,
            type: .otherSpace
          ))
        statistics.append(
          FileKindStatistic(
            kindID: FileKind.otherSpaceID,
            count: 1,
            totalSize: other
          ))
      }

      if showFreeSpace, volume.available > 0 {
        children.append(
          FileNode(
            id: result.root.id + "\u{0}free-space",
            path: result.root.path,
            name: "Free Space",
            isDirectory: false,
            size: volume.available,
            kindID: FileKind.freeSpaceID,
            type: .freeSpace
          ))
        statistics.append(
          FileKindStatistic(
            kindID: FileKind.freeSpaceID,
            count: 1,
            totalSize: volume.available
          ))
      }
    }

    rootNode = result.root.replacingChildren(children)
    treeRevision = UUID()
    kindStatistics = statistics.sorted { $0.totalSize > $1.totalSize }
    selectedNode = priorSelectedID.flatMap { rootNode?.node(withID: $0) }
    zoomedNode = priorZoomedID.flatMap { rootNode?.node(withID: $0) }
    rebuildFilteredNodes()
  }

  private func rebuildFilteredNodes() {
    filterTask?.cancel()
    guard let selectedKindID, let root = displayRoot else {
      filteredNodes = []
      return
    }

    let token = UUID()
    filterToken = token
    let showPackageContents = showPackageContents
    filterTask = Task.detached(priority: .userInitiated) { [weak self] in
      let nodes = root.visibleEntries(
        showPackageContents: showPackageContents,
        kindID: selectedKindID
      )
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard self?.filterToken == token else { return }
        self?.filteredNodes = nodes
      }
    }
  }
}
