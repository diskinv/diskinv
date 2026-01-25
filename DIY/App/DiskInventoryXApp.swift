//
//  DiskInventoryYApp.swift
//  DiskInventoryY
//
//  Modern SwiftUI rewrite of Disk Inventory X
//  GPL v3 License
//

import SwiftUI

@main
struct DiskInventoryYApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder...") {
                    appState.showOpenPanel()
                }
                .keyboardShortcut("o")
            }

            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    appState.zoomIn()
                }
                .keyboardShortcut("+")
                .disabled(appState.selectedNode == nil || !(appState.selectedNode?.isDirectory ?? false))

                Button("Zoom Out") {
                    appState.zoomOut()
                }
                .keyboardShortcut("-")
                .disabled(appState.zoomStack.isEmpty)

                Divider()

                Button("Refresh") {
                    Task {
                        await appState.refresh()
                    }
                }
                .keyboardShortcut("r")
                .disabled(appState.rootNode == nil)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
