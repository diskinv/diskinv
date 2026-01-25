//
//  SidebarView.swift
//  DiskInventoryX
//
//  Sidebar showing file kind statistics
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List(selection: $appState.selectedKind) {
            if !appState.kindStatistics.isEmpty {
                Section("File Types") {
                    ForEach(appState.kindStatistics) { stat in
                        FileKindRow(statistic: stat)
                            .tag(stat.kindName)
                    }
                }
            }

            if let root = appState.rootNode {
                Section("Summary") {
                    LabeledContent("Total Size") {
                        Text(FileSizeFormatter.string(from: root.size))
                            .monospacedDigit()
                    }

                    LabeledContent("File Types") {
                        Text("\(appState.kindStatistics.count)")
                            .monospacedDigit()
                    }

                    let totalFiles = appState.kindStatistics.reduce(0) { $0 + $1.count }
                    LabeledContent("Files") {
                        Text("\(totalFiles)")
                            .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("File Types")
    }
}

struct FileKindRow: View {
    let statistic: FileKindStatistic

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statistic.color)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(statistic.kindName)
                    .lineLimit(1)

                Text("\(statistic.formattedCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(statistic.formattedSize)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    SidebarView()
        .environmentObject(AppState())
        .frame(width: 250, height: 400)
}
