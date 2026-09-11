import AppKit
import SwiftUI

@main
struct DiskInventoryXsApp: App {
  @StateObject private var appState = AppState()

  init() {
    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
      let image = NSImage(contentsOf: url)
    {
      NSApplication.shared.applicationIconImage = image
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(appState)
    }
    .defaultSize(width: 1120, height: 720)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("Open Folder...") {
          appState.showOpenPanel()
        }
        .keyboardShortcut("o")
      }

      CommandGroup(after: .toolbar) {
        Button("Zoom In") { appState.zoomIn() }
          .keyboardShortcut("+")
          .disabled(!(appState.selectedNode?.isDirectory ?? false))
        Button("Zoom Out") { appState.zoomOut() }
          .keyboardShortcut("-")
          .disabled(appState.zoomStack.isEmpty)
        Button("Zoom to Root") { appState.zoomToRoot() }
          .disabled(appState.zoomedNode == nil)
        Divider()
        Button("Refresh") { appState.refresh() }
          .keyboardShortcut("r")
          .disabled(appState.rootNode == nil || appState.isScanning)
        if appState.isScanning {
          Button("Cancel Scan") { appState.cancelScan() }
            .keyboardShortcut(.cancelAction)
        }
      }
    }

    Settings {
      SettingsView()
        .environmentObject(appState)
    }
  }
}
