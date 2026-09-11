import Foundation
import XCTest

@testable import DiskInventoryXs

final class FileScannerTests: XCTestCase {
  func testScanIncludesHiddenFilesAndPackageContents() async throws {
    let fixture = try TemporaryDirectory()
    try fixture.write(bytes: 11, to: ".hidden")
    try fixture.write(bytes: 17, to: "visible.txt")
    try fixture.write(bytes: 23, to: "Example.app/Contents/payload.bin")
    try fixture.write(
      bytes: Array("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict></dict></plist>".utf8),
      to: "Example.app/Contents/Info.plist"
    )

    let result = try await FileScanner.scan(
      url: fixture.url,
      options: ScanOptions(sizeMode: .logical),
      progress: { _ in }
    )

    let paths = Set(result.root.visibleEntries(showPackageContents: true).map(\.path))
    XCTAssertTrue(paths.contains { $0.hasSuffix("/.hidden") })
    XCTAssertTrue(paths.contains { $0.hasSuffix("/visible.txt") })
    XCTAssertTrue(paths.contains { $0.hasSuffix("/Example.app/Contents/payload.bin") })
    XCTAssertEqual(result.filesScanned, 4)
    XCTAssertEqual(result.foldersScanned, 3)
    XCTAssertEqual(result.issueCount, 0)
    XCTAssertGreaterThanOrEqual(result.root.size, 51)
  }

  func testScanDoesNotFollowSymbolicLinks() async throws {
    let fixture = try TemporaryDirectory()
    try fixture.write(bytes: 9, to: "target/file.dat")
    try FileManager.default.createSymbolicLink(
      atPath: fixture.url.appendingPathComponent("link").path,
      withDestinationPath: fixture.url.appendingPathComponent("target").path
    )

    let result = try await FileScanner.scan(
      url: fixture.url,
      options: ScanOptions(sizeMode: .logical),
      progress: { _ in }
    )

    let entries = result.root.visibleEntries(showPackageContents: true)
    XCTAssertEqual(entries.filter { $0.name == "file.dat" }.count, 1)
    XCTAssertEqual(entries.filter { $0.name == "link" }.count, 1)
  }

  func testParallelAndSerialScansMatch() async throws {
    let fixture = try TemporaryDirectory()
    for index in 0..<128 {
      try fixture.write(bytes: index + 1, to: "folder-\(index % 8)/file-\(index).dat")
    }

    let serial = try await FileScanner.scan(
      url: fixture.url,
      options: ScanOptions(sizeMode: .logical, workerCount: 1),
      progress: { _ in }
    )
    let parallel = try await FileScanner.scan(
      url: fixture.url,
      options: ScanOptions(sizeMode: .logical, workerCount: 4),
      progress: { _ in }
    )

    let serialEntries = Dictionary(
      uniqueKeysWithValues: serial.root.visibleEntries(showPackageContents: true).map {
        ($0.path, $0.size)
      })
    let parallelEntries = Dictionary(
      uniqueKeysWithValues: parallel.root.visibleEntries(showPackageContents: true).map {
        ($0.path, $0.size)
      })
    XCTAssertEqual(parallelEntries, serialEntries)
    XCTAssertEqual(parallel.filesScanned, serial.filesScanned)
    XCTAssertEqual(parallel.foldersScanned, serial.foldersScanned)
    XCTAssertEqual(parallel.issueCount, serial.issueCount)
    XCTAssertEqual(parallel.root.size, serial.root.size)
  }

  func testWorkerCountResolution() {
    XCTAssertEqual(ScanOptions.resolveWorkerCount(0, activeProcessorCount: 12), 11)
    XCTAssertEqual(ScanOptions.resolveWorkerCount(0, activeProcessorCount: 1), 1)
    XCTAssertEqual(ScanOptions.resolveWorkerCount(6, activeProcessorCount: 12), 6)
    XCTAssertEqual(
      ScanOptions.resolveWorkerCount(100, activeProcessorCount: 12),
      ScanOptions.maximumWorkerCount
    )
  }

  func testTreeMapStaysInsideBoundsWithoutOverlap() {
    let children = [60, 30, 10].enumerated().map { index, size in
      FileNode(
        path: "/\(index)",
        name: "\(index)",
        isDirectory: false,
        size: UInt64(size),
        kindID: FileKind.documentID
      )
    }
    let root = FileNode(
      path: "/",
      name: "/",
      isDirectory: true,
      size: 100,
      kindID: FileKind.folderID,
      children: children
    )
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
    let rectangles = TreeMapLayout.layout(
      node: root,
      in: bounds,
      showPackageContents: true
    )

    XCTAssertEqual(rectangles.count, 3)
    for rectangle in rectangles {
      XCTAssertTrue(bounds.contains(rectangle.rect), "\(rectangle.rect)")
    }
    for left in rectangles.indices {
      for right in rectangles.indices where left < right {
        let overlap = rectangles[left].rect.intersection(rectangles[right].rect)
        XCTAssertTrue(overlap.isNull || overlap.width == 0 || overlap.height == 0)
      }
    }
  }

  func testDenseTreeMapUsesPixelAlignedRealLeaves() {
    let children = (0..<40).map { directoryIndex in
      let files = (0..<500).map { fileIndex in
        FileNode(
          path: "/\(directoryIndex)/\(fileIndex)",
          name: "\(fileIndex)",
          isDirectory: false,
          size: 1,
          kindID: FileKind.documentID
        )
      }
      return FileNode(
        path: "/\(directoryIndex)",
        name: "\(directoryIndex)",
        isDirectory: true,
        size: UInt64(files.count),
        kindID: FileKind.folderID,
        children: files
      )
    }
    let root = FileNode(
      path: "/",
      name: "/",
      isDirectory: true,
      size: UInt64(children.count),
      kindID: FileKind.folderID,
      children: children
    )
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
    let rectangles = TreeMapLayout.layout(
      node: root,
      in: bounds,
      showPackageContents: true,
      pixelScale: 2
    )

    let coveredArea = rectangles.reduce(0) { $0 + $1.rect.width * $1.rect.height }
    XCTAssertGreaterThan(rectangles.count, 10_000)
    XCTAssertLessThan(rectangles.count, 20_000)
    XCTAssertTrue(rectangles.allSatisfy { !$0.node.isDirectory })
    XCTAssertEqual(Set(rectangles.map { $0.node.id }).count, rectangles.count)
    XCTAssertEqual(coveredArea, bounds.width * bounds.height, accuracy: 0.1)
    for rectangle in rectangles {
      XCTAssertEqual(rectangle.rect.minX * 2, (rectangle.rect.minX * 2).rounded())
      XCTAssertEqual(rectangle.rect.minY * 2, (rectangle.rect.minY * 2).rounded())
      XCTAssertEqual(rectangle.rect.width * 2, (rectangle.rect.width * 2).rounded())
      XCTAssertEqual(rectangle.rect.height * 2, (rectangle.rect.height * 2).rounded())
    }
    for rectangle in rectangles.enumerated() where rectangle.offset.isMultiple(of: 211) {
      let hit = TreeMapLayout.rectangle(
        at: CGPoint(x: rectangle.element.rect.midX, y: rectangle.element.rect.midY),
        in: rectangles
      )
      XCTAssertEqual(hit?.node.id, rectangle.element.node.id)
    }
  }

  func testSizeAdditionSaturates() {
    XCTAssertEqual(UInt64.max.saturatingAdding(1), .max)
  }
}

private final class TemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("DiskInventoryCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }

  func write(bytes count: Int, to relativePath: String) throws {
    try write(bytes: Array(repeating: UInt8(0x41), count: count), to: relativePath)
  }

  func write(bytes: [UInt8], to relativePath: String) throws {
    let destination = url.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(bytes).write(to: destination)
  }
}
