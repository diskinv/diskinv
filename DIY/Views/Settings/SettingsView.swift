//
//  SettingsView.swift
//  DiskInventoryX
//
//  Application settings/preferences
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            TreeMapSettingsTab()
                .tabItem {
                    Label("TreeMap", systemImage: "square.grid.2x2")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 300)
    }
}

struct GeneralSettingsTab: View {
    @AppStorage("showPhysicalSize") private var showPhysicalSize = false
    @AppStorage("showPackageContents") private var showPackageContents = false
    @AppStorage("ignoreCreatorCodes") private var ignoreCreatorCodes = true
    @AppStorage("showFreeSpace") private var showFreeSpace = true
    @AppStorage("showOtherSpace") private var showOtherSpace = true

    var body: some View {
        Form {
            Section("File Sizes") {
                Toggle("Show physical file size (disk space used)", isOn: $showPhysicalSize)
                    .help("Show the actual disk space used instead of logical file size")
            }

            Section("Packages & Bundles") {
                Toggle("Show package contents", isOn: $showPackageContents)
                    .help("Display contents of application bundles and packages")

                Toggle("Ignore creator codes when determining file type", isOn: $ignoreCreatorCodes)
                    .help("Use file extension instead of legacy creator codes")
            }

            Section("Volume Display") {
                Toggle("Show free space", isOn: $showFreeSpace)
                    .help("Display free space on the volume in the treemap")

                Toggle("Show other space", isOn: $showOtherSpace)
                    .help("Display space used by other files on the volume")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct TreeMapSettingsTab: View {
    @AppStorage("cushionShading") private var cushionShading = true
    @AppStorage("showLabels") private var showLabels = true
    @AppStorage("minRectSize") private var minRectSize = 3.0

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Cushion shading", isOn: $cushionShading)
                    .help("Apply gradient shading for a 3D cushion effect")

                Toggle("Show file name labels", isOn: $showLabels)
                    .help("Display file names on treemap rectangles")
            }

            Section("Performance") {
                Slider(value: $minRectSize, in: 1...10, step: 1) {
                    Text("Minimum rectangle size")
                } minimumValueLabel: {
                    Text("1")
                } maximumValueLabel: {
                    Text("10")
                }
                .help("Minimum size in pixels for treemap rectangles")

                Text("Smaller values show more detail but may be slower")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Disk Inventory X")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 2.0")
                .foregroundStyle(.secondary)

            Text("A disk usage visualization tool using treemaps")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider()

            Text("Originally by Tjark Derlien")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Text("Swift rewrite - 2024")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Link("GPL v3 License", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsView()
}
