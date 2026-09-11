import AppKit
import SwiftUI

struct FileListView: View {
  @EnvironmentObject private var appState: AppState
  @State private var expandedNodes: Set<String> = []

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(appState.selectedKindID == nil ? "name" : "matching files")
        Spacer()
        Text("size")
          .frame(width: 78, alignment: .trailing)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(.bar)

      Divider()

      if let root = appState.displayRoot {
        List(selection: $appState.selectedNode) {
          if appState.selectedKindID == nil {
            ForEach(root.children) { node in
              FileNodeRow(node: node, expandedNodes: $expandedNodes)
            }
          } else {
            ForEach(appState.filteredNodes) { node in
              FileRow(node: node, showsPath: true)
                .tag(node)
            }
          }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
      } else {
        Color(nsColor: .textBackgroundColor)
      }
    }
    .frame(minWidth: 250, idealWidth: 300)
  }
}

private struct FileNodeRow: View {
  @EnvironmentObject private var appState: AppState
  let node: FileNode
  @Binding var expandedNodes: Set<String>

  private var canExpand: Bool {
    node.isDirectory
      && !node.children.isEmpty
      && (!node.isPackage || appState.showPackageContents)
  }

  private var expanded: Binding<Bool> {
    Binding(
      get: { expandedNodes.contains(node.id) },
      set: { isExpanded in
        if isExpanded {
          expandedNodes.insert(node.id)
        } else {
          expandedNodes.remove(node.id)
        }
      }
    )
  }

  var body: some View {
    if canExpand {
      DisclosureGroup(isExpanded: expanded) {
        ForEach(node.children) { child in
          FileNodeRow(node: child, expandedNodes: $expandedNodes)
        }
      } label: {
        FileRow(node: node)
          .tag(node)
      }
    } else {
      FileRow(node: node)
        .tag(node)
    }
  }
}

private struct FileRow: View {
  @EnvironmentObject private var appState: AppState
  let node: FileNode
  var showsPath = false

  var body: some View {
    HStack(spacing: 6) {
      FileIcon(node: node)

      VStack(alignment: .leading, spacing: 1) {
        Text(node.name)
          .lineLimit(1)
          .truncationMode(.middle)
        if showsPath {
          Text(node.path)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }

      Spacer(minLength: 8)

      Text(FileSizeFormatter.string(from: node.size))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 78, alignment: .trailing)
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      appState.selectedNode = node
      appState.zoomIn()
    }
    .contextMenu {
      if let url = node.url {
        Button("Open") {
          NSWorkspace.shared.open(url)
        }
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        if node.isDirectory {
          Button("Zoom In") {
            appState.selectedNode = node
            appState.zoomIn()
          }
          .disabled(node.isPackage && !appState.showPackageContents)
        }

        Divider()

        Button("Move to Trash", role: .destructive) {
          appState.trashCandidate = node
        }
        .disabled(node.id == appState.rootNode?.id)
      }
    }
    .help(node.path)
  }
}

private struct FileIcon: View {
  let node: FileNode

  var body: some View {
    Group {
      switch node.type {
      case .freeSpace:
        Image(systemName: "externaldrive")
      case .otherSpace:
        Image(systemName: "questionmark.folder")
      case .regular:
        Image(nsImage: NSWorkspace.shared.icon(forFile: node.path))
          .resizable()
      }
    }
    .frame(width: 16, height: 16)
    .accessibilityHidden(true)
  }
}
