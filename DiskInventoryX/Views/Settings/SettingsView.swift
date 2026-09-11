import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    TabView {
      Form {
        Picker(
          "File sizes",
          selection: Binding(
            get: { appState.sizeMode },
            set: { appState.sizeMode = $0 }
          )
        ) {
          ForEach(FileSizeMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        if let scannedMode = appState.scannedSizeMode, scannedMode != appState.sizeMode {
          Text("Refresh the scan to use the new size mode.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Toggle("Show package contents", isOn: $appState.showPackageContents)
        Toggle("Show free space for volumes", isOn: $appState.showFreeSpace)
        Toggle("Show other used space for volumes", isOn: $appState.showOtherSpace)
      }
      .formStyle(.grouped)
      .padding()
      .tabItem { Label("General", systemImage: "gear") }

      TreeMapSettings()
        .tabItem { Label("Treemap", systemImage: "square.grid.3x3.fill") }

      VStack(spacing: 12) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .frame(width: 72, height: 72)
        Text("Disk Inventory Xs")
          .font(.title2.weight(.semibold))
        Text("Version 3.0")
          .foregroundStyle(.secondary)
        Text("Originally created by Tjark Derlien. Licensed under GPL v3.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding()
      .tabItem { Label("About", systemImage: "info.circle") }
    }
    .frame(width: 470, height: 300)
  }
}

private struct TreeMapSettings: View {
  @AppStorage("cushionShading") private var cushionShading = true
  @AppStorage("showLabels") private var showLabels = false
  @AppStorage("minimumRectangleSize") private var minimumRectangleSize = 2.0

  var body: some View {
    Form {
      Toggle("Cushion shading", isOn: $cushionShading)
      Toggle("Show file names", isOn: $showLabels)
      LabeledContent("Minimum rectangle size") {
        Slider(value: $minimumRectangleSize, in: 1...8, step: 1)
          .frame(width: 220)
        Text("\(minimumRectangleSize, specifier: "%.0f") px")
          .monospacedDigit()
          .frame(width: 42, alignment: .trailing)
      }
    }
    .formStyle(.grouped)
    .padding()
  }
}
