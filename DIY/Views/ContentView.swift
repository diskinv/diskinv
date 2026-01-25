//
//  ContentView.swift
//  DiskInventoryX
//
//  Main application view with NavigationSplitView
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: File kind statistics
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        } content: {
            // File list
            FileListView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 500)
        } detail: {
            // TreeMap
            TreeMapContainerView()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { appState.showOpenPanel() }) {
                    Label("Open Folder", systemImage: "folder")
                }
                .help("Open a folder to analyze")

                Divider()

                Button(action: { appState.zoomIn() }) {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .help("Zoom into selected folder")
                .disabled(appState.selectedNode == nil || !(appState.selectedNode?.isDirectory ?? false))

                Button(action: { appState.zoomOut() }) {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .help("Zoom out to parent folder")
                .disabled(appState.zoomStack.isEmpty)

                Button(action: { appState.zoomToRoot() }) {
                    Label("Zoom to Root", systemImage: "arrow.up.to.line")
                }
                .help("Zoom to root folder")
                .disabled(appState.zoomedNode == nil)

                Divider()

                Button(action: {
                    Task { await appState.refresh() }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Rescan current folder")
                .disabled(appState.rootNode == nil || appState.isScanning)
            }
        }
        .navigationTitle(navigationTitle)
        .overlay {
            if appState.isScanning {
                ScanningOverlay()
            } else if appState.rootNode == nil {
                WelcomeView()
            }
        }
        .alert("Error", isPresented: .constant(appState.errorMessage != nil)) {
            Button("OK") {
                appState.errorMessage = nil
            }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    private var navigationTitle: String {
        if let zoomed = appState.zoomedNode {
            return zoomed.name
        } else if let root = appState.rootNode {
            return root.name
        } else {
            return "Disk Inventory X"
        }
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ContentUnavailableView {
            Label("No Folder Selected", systemImage: "folder.badge.questionmark")
        } description: {
            Text("Open a folder to analyze disk usage and visualize it as a treemap.")
        } actions: {
            Button("Open Folder...") {
                appState.showOpenPanel()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Scanning Overlay

struct ScanningOverlay: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)

                Text("Scanning...")
                    .font(.headline)

                if let progress = appState.scanProgress {
                    VStack(spacing: 4) {
                        Text(progress.currentFolder)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text("\(progress.filesScanned) files, \(progress.foldersScanned) folders")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

// MARK: - TreeMap Container

struct TreeMapContainerView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let root = appState.displayRoot {
                TreeMapView(
                    root: root,
                    selectedNode: $appState.selectedNode,
                    colorProvider: { appState.color(for: $0) }
                )
            } else {
                Color.clear
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .frame(width: 1000, height: 700)
}
