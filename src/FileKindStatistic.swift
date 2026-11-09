//
//  FileKindStatistic.swift
//  Disk Inventory Xs
//
//  Swift port of FileKindStatistic (formerly embedded in FileSystemDoc.{h,m}).
//  Tracks the count and total size of all files of one kind (e.g. all MP3s).
//
//  GPL v3
//

import Foundation

@objc(FileKindStatistic)
final class FileKindStatistic: NSObject {

    private let _kindName: String
    private var _size: UInt64 = 0
    //Private backing storage: native Swift set keyed on FSItem identity
    //(FSItem is an NSObject whose isEqual:/hash are identity-based). The public
    //`items` (NSSet) and itemEnumerator() bridge to NS* at the boundary.
    private var _items: Set<FSItem>

    @objc(initWithItem:)
    init(item: FSItem) {
        _kindName = item.kindName() ?? ""
        _size = item.sizeValue()
        _items = [item]
        super.init()
    }

    @objc(addItem:)
    func add(_ item: FSItem) {
        assert(!_items.contains(item))
        _items.insert(item)
        _size += item.sizeValue()
    }

    @objc(removeItem:)
    func remove(_ item: FSItem) {
        assert(_items.contains(item))
        _size -= item.sizeValue()
        _items.remove(item)
    }

    @objc var kindName: String { _kindName }

    @objc override var description: String {
        "\(_kindName) {\(fileCount) files; \(String(format: "%.1f", Float(_size) / 1024)) kB}"
    }

    // # of files of this kind
    @objc var fileCount: UInt { UInt(_items.count) }

    // sum of sizes of files of this kind
    @objc var size: UInt64 { _size }

    @objc func recalculateSize() {
        _size = 0
        for item in _items {
            _size += item.sizeValue()
        }
    }

    //bridge the Swift Set back to NSSet to preserve the original return type
    @objc var items: NSSet { _items as NSSet }

    @objc func itemEnumerator() -> NSEnumerator {
        (_items as NSSet).objectEnumerator()
    }

    // compare the size descendingly
    @objc(compareSizeDescendingly:)
    func compareSizeDescendingly(_ other: FileKindStatistic) -> ComparisonResult {
        let mySize = _size
        let otherSize = other.size

        // we want the sorting to be descending
        if mySize < otherSize { return .orderedDescending }
        if mySize > otherSize { return .orderedAscending }

        // same size: order by name
        return _kindName.compare(other.kindName, options: .numeric)
    }

    // Folded in from the former FileKindStatistic(AllKinds) category. A real
    // FileKindStatistic is never the "all kinds" item (that sentinel is a
    // faked NSDictionary with its own isAllFileKindsItem returning YES).
    @objc func isAllFileKindsItem() -> Bool {
        false
    }
}
