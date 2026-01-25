//
//  FileScanner.swift
//  DiskInventoryX
//
//  Async file system scanner
//

import Foundation
import UniformTypeIdentifiers

actor FileScanner {
    private var isCancelled = false

    // MARK: - Public API

    func cancel() {
        isCancelled = true
    }

    func scan(
        url: URL,
        showPackageContents: Bool,
        usePhysicalSize: Bool,
        progress: @escaping (String, Int, Int) -> Void
    ) async throws -> FileNode {
        isCancelled = false

        var fileCount = 0
        var folderCount = 0

        let root = try await scanDirectory(
            url: url,
            parent: nil,
            showPackageContents: showPackageContents,
            usePhysicalSize: usePhysicalSize,
            fileCount: &fileCount,
            folderCount: &folderCount,
            progress: progress
        )

        root.sortChildrenBySize()
        return root
    }

    // MARK: - Private Implementation

    private func scanDirectory(
        url: URL,
        parent: FileNode?,
        showPackageContents: Bool,
        usePhysicalSize: Bool,
        fileCount: inout Int,
        folderCount: inout Int,
        progress: @escaping (String, Int, Int) -> Void
    ) async throws -> FileNode {
        guard !isCancelled else {
            throw CancellationError()
        }

        let resourceKeys: Set<URLResourceKey> = [
            .nameKey,
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentTypeKey,
            .isSymbolicLinkKey,
            .isAliasFileKey
        ]

        let values = try url.resourceValues(forKeys: resourceKeys)

        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let isSymlink = values.isSymbolicLink ?? false
        let isAlias = values.isAliasFile ?? false

        let size: UInt64
        if usePhysicalSize {
            size = UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        } else {
            size = UInt64(values.fileSize ?? 0)
        }

        let node = FileNode(
            url: url,
            name: values.name ?? url.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: isPackage,
            size: isDirectory ? 0 : size
        )
        node.parent = parent

        // Report progress
        if isDirectory {
            folderCount += 1
            progress(url.lastPathComponent, fileCount, folderCount)
        } else {
            fileCount += 1
        }

        // Don't follow symlinks or aliases to avoid infinite loops
        if isSymlink || isAlias {
            return node
        }

        // Scan children if this is a directory (and not a package, unless configured to show package contents)
        if isDirectory && (showPackageContents || !isPackage) {
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles]
                )

                for childURL in contents {
                    guard !isCancelled else {
                        throw CancellationError()
                    }

                    do {
                        let child = try await scanDirectory(
                            url: childURL,
                            parent: node,
                            showPackageContents: showPackageContents,
                            usePhysicalSize: usePhysicalSize,
                            fileCount: &fileCount,
                            folderCount: &folderCount,
                            progress: progress
                        )
                        node.children.append(child)
                        node.size += child.size
                    } catch {
                        // Skip files we can't access (permission denied, etc.)
                        continue
                    }
                }
            } catch {
                // Can't enumerate directory, return node with no children
            }
        }

        return node
    }
}
