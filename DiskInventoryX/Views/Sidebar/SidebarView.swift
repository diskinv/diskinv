import SwiftUI

struct SidebarView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Text("color")
          .frame(width: 34, alignment: .leading)
        Text("kind")
        Spacer()
        Text("size")
          .frame(width: 72, alignment: .trailing)
        Text("files")
          .frame(width: 48, alignment: .trailing)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(.bar)

      Divider()

      List(selection: $appState.selectedKindID) {
        ForEach(appState.kindStatistics) { statistic in
          FileKindRow(statistic: statistic)
            .tag(statistic.kindID)
        }
      }
      .listStyle(.inset(alternatesRowBackgrounds: true))

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Button("All files") {
            appState.selectedKindID = nil
          }
          .buttonStyle(.link)
          .disabled(appState.selectedKindID == nil)

          Spacer()

          if appState.scanIssueCount > 0 {
            Button("\(appState.scanIssueCount) unreadable") {
              appState.showsScanIssues = true
            }
            .buttonStyle(.link)
            .foregroundStyle(.orange)
          }
        }

        if let root = appState.rootNode {
          Text(
            "\(appState.filesScanned.formatted()) files, \(appState.foldersScanned.formatted()) folders"
          )
          Text(FileSizeFormatter.string(from: root.size))
            .monospacedDigit()
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(8)
      .background(.bar)
    }
    .frame(minWidth: 260, idealWidth: 300)
  }
}

private struct FileKindRow: View {
  @EnvironmentObject private var appState: AppState
  let statistic: FileKindStatistic

  var body: some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 2)
        .fill(appState.color(for: statistic.kindID))
        .frame(width: 34, height: 14)
        .overlay {
          RoundedRectangle(cornerRadius: 2)
            .stroke(.black.opacity(0.2), lineWidth: 0.5)
        }

      Text(appState.kindName(for: statistic.kindID))
        .lineLimit(1)

      Spacer(minLength: 6)

      Text(FileSizeFormatter.string(from: statistic.totalSize))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 72, alignment: .trailing)

      Text(statistic.count.formatted())
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 48, alignment: .trailing)
    }
  }
}
