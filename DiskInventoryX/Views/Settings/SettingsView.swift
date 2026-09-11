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

        LabeledContent("Parallel scan workers") {
          Stepper(
            value: $appState.scanWorkerCount,
            in: 0...ScanOptions.maximumWorkerCount
          ) {
            Text(workerCountLabel)
              .monospacedDigit()
          }
        }
        Text("0 uses all but one active CPU core. Changes apply to the next scan.")
          .font(.caption)
          .foregroundStyle(.secondary)

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
    .frame(width: 470, height: 350)
  }

  private var workerCountLabel: String {
    appState.scanWorkerCount == 0
      ? "Automatic (\(appState.effectiveScanWorkerCount))"
      : "\(appState.scanWorkerCount)"
  }
}

private struct TreeMapSettings: View {
  @AppStorage("cushionShading") private var cushionShading = true
  @AppStorage("showLabels") private var showLabels = false

  var body: some View {
    Form {
      Toggle("Cushion shading", isOn: $cushionShading)
      Toggle("Show file names", isOn: $showLabels)
    }
    .formStyle(.grouped)
    .padding()
  }
}
