//
//  FSItemScanTests.swift
//  Disk Inventory XTests
//
//  Scans the generated fixture tree (see TestFixtures) with FSItem and asserts
//  the resulting tree's structure and sizes. Uses logical sizes (recalculated
//  explicitly) so the assertions are exact and deterministic.
//
//  GPL v3
//

import XCTest
import Cocoa
@testable import Disk_Inventory_Xs

final class FSItemScanTests: XCTestCase {

    private static var fixturesRoot: URL!

    override class func setUp() {
        super.setUp()
        fixturesRoot = try! TestFixtures.ensure()
    }

    // Scans the fixtures and returns the root FSItem with logical sizes.
    private func scanFixtures() throws -> FSItem {
        let root = FSItem(url: Self.fixturesRoot as NSURL)
        try root.loadChildren()
        // the scanner ends with a physical-size recalc; redo with logical so the
        // assertions match the exact bytes we wrote
        root.recalculateSize(false, updateParent: false)
        return root
    }

    // MARK: - fixtures

    func testFixturesExist() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.fixturesRoot.path),
                      "fixtures should have been generated")
    }

    // MARK: - structure

    func testRootIsFolder() throws {
        XCTAssertTrue(try scanFixtures().isFolder())
    }

    func testTopLevelChildCount() throws {
        XCTAssertEqual(Int(try scanFixtures().childCount()), TestFixtures.topLevelChildCount)
    }

    func testTotalFileCount() throws {
        XCTAssertEqual(countFiles(try scanFixtures()), TestFixtures.fileCount)
    }

    func testTotalFolderCount() throws {
        // count nested folders (excluding the scanned root itself)
        XCTAssertEqual(countFolders(try scanFixtures()) - 1, TestFixtures.folderCount)
    }

    func testNestedFolderResolves() throws {
        let root = try scanFixtures()
        let folderA = child(of: root, named: "folderA")
        XCTAssertNotNil(folderA)
        let folderA1 = folderA.flatMap { child(of: $0, named: "folderA1") }
        XCTAssertNotNil(folderA1, "folderA/folderA1 should resolve")
        XCTAssertTrue(folderA1!.isFolder())
    }

    func testEmptyFolder() throws {
        let empty = child(of: try scanFixtures(), named: "emptyFolder")
        XCTAssertNotNil(empty)
        XCTAssertTrue(empty!.isFolder())
        XCTAssertEqual(empty!.childCount(), 0)
        XCTAssertEqual(empty!.sizeValue(), 0)
    }

    // MARK: - sizes

    func testTotalLogicalSize() throws {
        XCTAssertEqual(try scanFixtures().sizeValue(), UInt64(TestFixtures.totalBytes))
    }

    func testKnownLeafFileSize() throws {
        let big = child(of: try scanFixtures(), named: "level0_2mb.dixfix")
        XCTAssertNotNil(big)
        XCTAssertFalse(big!.isFolder())
        XCTAssertEqual(big!.sizeValue(), 2 * 1024 * 1024)
    }

    func testFolderSizeAggregatesChildren() throws {
        let folderA = child(of: try scanFixtures(), named: "folderA")
        XCTAssertNotNil(folderA)
        // 1 MB + 512 KB + 256 KB (the last nested in folderA1)
        XCTAssertEqual(folderA!.sizeValue(), UInt64((1024 + 512 + 256) * 1024))
    }

    // MARK: - helpers

    private func child(of item: FSItem, named name: String) -> FSItem? {
        var i: UInt = 0
        while i < item.childCount() {
            if let c = item.child(at: i), c.name() == name { return c }
            i += 1
        }
        return nil
    }

    private func countFiles(_ item: FSItem) -> Int {
        guard item.isFolder() else { return 1 }
        return eachChild(item).reduce(0) { $0 + countFiles($1) }
    }

    private func countFolders(_ item: FSItem) -> Int {
        guard item.isFolder() else { return 0 }
        return 1 + eachChild(item).reduce(0) { $0 + countFolders($1) }
    }

    private func eachChild(_ item: FSItem) -> [FSItem] {
        var result: [FSItem] = []
        var i: UInt = 0
        while i < item.childCount() {
            if let c = item.child(at: i) { result.append(c) }
            i += 1
        }
        return result
    }
}

// Regression coverage for Swift image ownership when AppKit copies NSCells.
final class ImageAndTextCellTests: XCTestCase {

    func testRepeatedCopiesKeepCachedIconAliveAndReleaseItAfterwards() {
        weak var cachedImage: NSImage?
        autoreleasepool {
            let cache = NSMutableDictionary()
            let original = ImageAndTextCell(textCell: "source")
            autoreleasepool {
                let image = NSImage(size: NSSize(width: 16, height: 16))
                cachedImage = image
                original.image = image
                cache.setObject(image, forKey: "icon" as NSString)
            }
            for _ in 0..<1000 {
                autoreleasepool {
                    let copy = original.copy() as! ImageAndTextCell
                    XCTAssertTrue(copy.image === original.image)
                    XCTAssertEqual(copy.stringValue, "source")
                }
                XCTAssertNotNil(cachedImage)
            }
            withExtendedLifetime((cache, original)) {}
        }
        XCTAssertNil(cachedImage, "the copied cells must not leak the image")
    }

    func testCopyKeepsImageAfterOriginalIsReleased() {
        weak var image: NSImage?
        let copy: ImageAndTextCell = autoreleasepool {
            let original = ImageAndTextCell(textCell: "source")
            let icon = NSImage(size: NSSize(width: 16, height: 16))
            image = icon
            original.image = icon
            return original.copy() as! ImageAndTextCell
        }
        XCTAssertNotNil(image)
        XCTAssertTrue(copy.image === image)
        copy.image = nil
        XCTAssertNil(image)
    }

    func testReplacingCopiedImagePreservesOriginal() {
        let original = ImageAndTextCell(textCell: "source")
        let image = NSImage(size: NSSize(width: 16, height: 16))
        original.image = image
        let copy = original.copy() as! ImageAndTextCell
        copy.image = NSImage(size: NSSize(width: 32, height: 32))
        XCTAssertTrue(original.image === image)
        XCTAssertFalse(copy.image === image)
        let empty = ImageAndTextCell(textCell: "empty").copy() as! ImageAndTextCell
        XCTAssertNil(empty.image)
        XCTAssertEqual(empty.stringValue, "empty")
    }
}
