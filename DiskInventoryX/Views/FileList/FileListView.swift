//
//  FileListView.swift
//  DiskInventoryX
//
//  Outline view showing file hierarchy
//

import SwiftUI

struct FileListView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let root = appState.displayRoot {
                List(selection: $appState.selectedNode) {
                    OutlineGroup(root.children, children: \.optionalChildren) { node in
                        FileRow(node: node)
                            .tag(node)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            } else {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "folder",
                    description: Text("Open a folder to see its contents")
                )
            }
        }
        .navigationTitle("Files")
    }
}

struct FileRow: View {
    let node: FileNode
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            // Icon
            Image(nsImage: node.icon)
                .resizable()
                .frame(width: 16, height: 16)

            // Name
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Kind (for non-folders)
            if !node.isDirectory {
                Text(node.kindName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            // Size
            Text(FileSizeFormatter.string(from: node.size))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)

            // Size bar
            SizeBar(
                size: node.size,
                maxSize: appState.displayRoot?.size ?? node.size,
                color: appState.color(for: node.kindName)
            )
            .frame(width: 60)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(node.url.path, inFileViewerRootedAtPath: "")
            }

            if node.isDirectory {
                Button("Zoom Into") {
                    appState.selectedNode = node
                    appState.zoomIn()
                }
            }

            Divider()

            Button("Move to Trash", role: .destructive) {
                moveToTrash(node)
            }
            .disabled(node.isSpecialItem)
        }
    }

    private func moveToTrash(_ node: FileNode) {
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            // Could notify appState to refresh
        } catch {
            // Handle error
        }
    }
}

struct SizeBar: View {
    let size: UInt64
    let maxSize: UInt64
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let fraction = maxSize > 0 ? CGFloat(size) / CGFloat(maxSize) : 0

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))

                Rectangle()
                    .fill(color)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

// MARK: - FileNode Extension

extension FileNode {
    /// Returns children for OutlineGroup, or nil if no children
    var optionalChildren: [FileNode]? {
        children.isEmpty ? nil : children
    }
}

#Preview {
    let appState = AppState()

    let root = FileNode(url: URL(fileURLWithPath: "/"), name: "Root", isDirectory: true, size: 1000)
    let folder = FileNode(url: URL(fileURLWithPath: "/folder"), name: "Documents", isDirectory: true, size: 600)
    let file1 = FileNode(url: URL(fileURLWithPath: "/folder/a.txt"), name: "readme.txt", size: 100)
    let file2 = FileNode(url: URL(fileURLWithPath: "/folder/b.pdf"), name: "report.pdf", size: 500)
    folder.children = [file1, file2]
    let file3 = FileNode(url: URL(fileURLWithPath: "/c.app"), name: "App.app", isPackage: true, size: 400)
    root.children = [folder, file3]

    return FileListView()
        .environmentObject(appState)
        .frame(width: 400, height: 300)
        .onAppear {
            appState.rootNode = root
        }
}
