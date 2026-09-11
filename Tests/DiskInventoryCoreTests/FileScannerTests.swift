import Foundation
import XCTest

@testable import DiskInventoryXs

final class FileScannerTests: XCTestCase {
  func testScanIncludesHiddenFilesAndPackageContents() throws {
    let fixture = try TemporaryDirectory()
    try fixture.write(bytes: 11, to: ".hidden")
    try fixture.write(bytes: 17, to: "visible.txt")
    try fixture.write(bytes: 23, to: "Example.app/Contents/payload.bin")
    try fixture.write(
      bytes: Array("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict></dict></plist>".utf8),
      to: "Example.app/Contents/Info.plist"
    )

    let result = try FileScanner.scan(
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

  func testScanDoesNotFollowSymbolicLinks() throws {
    let fixture = try TemporaryDirectory()
    try fixture.write(bytes: 9, to: "target/file.dat")
    try FileManager.default.createSymbolicLink(
      atPath: fixture.url.appendingPathComponent("link").path,
      withDestinationPath: fixture.url.appendingPathComponent("target").path
    )

    let result = try FileScanner.scan(
      url: fixture.url,
      options: ScanOptions(sizeMode: .logical),
      progress: { _ in }
    )

    let entries = result.root.visibleEntries(showPackageContents: true)
    XCTAssertEqual(entries.filter { $0.name == "file.dat" }.count, 1)
    XCTAssertEqual(entries.filter { $0.name == "link" }.count, 1)
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
      showPackageContents: true,
      minimumSize: 1
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
