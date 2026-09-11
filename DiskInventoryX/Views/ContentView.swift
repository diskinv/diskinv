import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var appState: AppState
  @State private var showsKinds = true

  var body: some View {
    VStack(spacing: 0) {
      HSplitView {
        FileListView()
          .frame(minWidth: 240, idealWidth: 300, maxWidth: 440)

        Group {
          if let root = appState.displayRoot {
            TreeMapView(root: root)
          } else {
            Color(nsColor: .windowBackgroundColor)
          }
        }
        .frame(minWidth: 420)

        if showsKinds {
          SidebarView()
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
        }
      }

      Divider()
      SelectionStatusBar()
    }
    .navigationTitle(appState.displayRoot?.name ?? "Disk Inventory Xs")
    .frame(minWidth: 940, minHeight: 500)
    .toolbar {
      ToolbarItemGroup {
        Button {
          appState.showOpenPanel()
        } label: {
          Label("Open Folder", systemImage: "folder")
        }
        .keyboardShortcut("o")

        Button {
          appState.refresh()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(appState.rootNode == nil || appState.isScanning)

        Button {
          appState.zoomIn()
        } label: {
          Label("Zoom In", systemImage: "plus.magnifyingglass")
        }
        .disabled(!(appState.selectedNode?.isDirectory ?? false))

        Button {
          appState.zoomOut()
        } label: {
          Label("Zoom Out", systemImage: "minus.magnifyingglass")
        }
        .disabled(appState.zoomStack.isEmpty)

        Button {
          showsKinds.toggle()
        } label: {
          Label("File Kinds", systemImage: "sidebar.right")
        }
      }
    }
    .overlay {
      if appState.isScanning {
        ScanningOverlay()
      } else if appState.rootNode == nil {
        WelcomeView()
      }
    }
    .alert(
      "Error",
      isPresented: Binding(
        get: { appState.errorMessage != nil },
        set: { if !$0 { appState.errorMessage = nil } }
      )
    ) {
      Button("OK") { appState.errorMessage = nil }
    } message: {
      Text(appState.errorMessage ?? "")
    }
    .confirmationDialog(
      "Move \"\(appState.trashCandidate?.name ?? "")\" to the Trash?",
      isPresented: Binding(
        get: { appState.trashCandidate != nil },
        set: { if !$0 { appState.trashCandidate = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Move to Trash", role: .destructive) {
        appState.confirmTrash()
      }
      Button("Cancel", role: .cancel) {
        appState.trashCandidate = nil
      }
    }
    .sheet(isPresented: $appState.showsScanIssues) {
      ScanIssuesView()
    }
  }
}

private struct WelcomeView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    ContentUnavailableView {
      Label("Choose a folder", systemImage: "externaldrive")
    } description: {
      Text(
        "Every entry beneath the selected folder will be included. Protected paths are reported after the scan."
      )
    } actions: {
      Button("Open Folder...") {
        appState.showOpenPanel()
      }
      .buttonStyle(.borderedProminent)
    }
  }
}

private struct ScanningOverlay: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    ZStack {
      Color.black.opacity(0.25)
        .ignoresSafeArea()

      VStack(spacing: 12) {
        ProgressView()
          .controlSize(.large)
        Text("Scanning every file...")
          .font(.headline)
        if let progress = appState.scanProgress {
          Text(progress.currentFolder)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(
            "\(progress.filesScanned.formatted()) files, \(progress.foldersScanned.formatted()) folders"
          )
          .monospacedDigit()
          .foregroundStyle(.secondary)
        }
        Button("Cancel") {
          appState.cancelScan()
        }
      }
      .frame(width: 340)
      .padding(24)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
  }
}

private struct SelectionStatusBar: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    HStack(spacing: 10) {
      if let node = appState.hoveredNode ?? appState.selectedNode {
        Text(node.path)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        Text(appState.kindName(for: node.kindID))
          .foregroundStyle(.secondary)
        Text(FileSizeFormatter.string(from: node.size))
          .monospacedDigit()
      } else if let root = appState.displayRoot {
        Text(root.path)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        Text(FileSizeFormatter.string(from: root.size))
          .monospacedDigit()
      } else {
        Text("Ready")
        Spacer()
      }
    }
    .font(.caption)
    .padding(.horizontal, 8)
    .frame(height: 24)
    .background(.bar)
  }
}

private struct ScanIssuesView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Unreadable paths")
        .font(.title2.weight(.semibold))
      Text(
        "The scan found \(appState.scanIssueCount.formatted()) paths macOS would not allow it to read. Nothing was silently treated as empty."
      )
      .foregroundStyle(.secondary)

      List(appState.scanIssues) { issue in
        VStack(alignment: .leading, spacing: 3) {
          Text(issue.path)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(issue.message)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      HStack {
        if appState.scanIssueCount > appState.scanIssues.count {
          Text("Showing the first \(appState.scanIssues.count.formatted()).")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding()
    .frame(width: 700, height: 430)
  }
}
