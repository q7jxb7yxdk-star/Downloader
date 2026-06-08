import SwiftUI

/// BT metadata 下載完成後顯示的檔案選擇視窗。
///
/// 使用者可以只下載 torrent 裡其中幾個檔案，避免浪費空間和流量。
struct TorrentFileSelectionSheet: View {
    @EnvironmentObject private var downloadManager: DownloadManager
    let selection: TorrentFileSelection

    /// 使用 Set 可以快速判斷某個 file index 是否被勾選。
    @State private var selectedIndexes: Set<Int>

    init(selection: TorrentFileSelection) {
        self.selection = selection
        // 首次選檔預設全選；重新選檔則保留目前選擇。
        _selectedIndexes = State(
            initialValue: selection.isReselection
                ? selection.selectedIndexes
                : Set(selection.files.map(\.index))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(selection.title)
                .font(.title2.bold())
                .lineLimit(1)

            HStack {
                Button("Select All") {
                    selectedIndexes = Set(selection.files.map(\.index))
                }
                .help("Select All")

                Button("Deselect All") {
                    selectedIndexes.removeAll()
                }
                .help("Deselect All")

                Spacer()

                Text(summaryText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            List(selection.files) { file in
                Toggle(isOn: binding(for: file.index)) {
                    HStack {
                        // 這裡顯示 torrent 內的原始相對路徑，可能包含資料夾名稱。
                        AdaptiveTooltipText(
                            file.path,
                            tooltipWidth: 1240,
                            tooltipLineLimit: 2
                        )

                        Spacer()

                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .binary))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(minHeight: 320)

            HStack {
                Spacer()

                Button("Cancel") {
                    downloadManager.cancelTorrentFileSelection(
                        itemID: selection.itemID,
                        isReselection: selection.isReselection
                    )
                }
                .keyboardShortcut(.cancelAction)
                .help("Cancel")

                Button(selection.isReselection ? "Apply Selection" : "Start Selected Files") {
                    downloadManager.chooseTorrentFiles(itemID: selection.itemID, indexes: selectedIndexes)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIndexes.isEmpty)
                .help(selection.isReselection ? "Apply Selection" : "Start Selected Files")
            }
        }
        .padding(24)
        .frame(width: 680, height: 520)
    }

    /// 顯示「已選幾個檔案 / 總大小」。
    private var summaryText: String {
        let selectedFiles = selection.files.filter { selectedIndexes.contains($0.index) }
        let totalSize = selectedFiles.reduce(Int64(0)) { $0 + $1.size }
        return "\(selectedFiles.count) of \(selection.files.count) files, \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .binary))"
    }

    /// 把 Set<Int> 包成 Toggle 需要的 Binding<Bool>。
    private func binding(for index: Int) -> Binding<Bool> {
        Binding(
            // Toggle 需要 Bool，但我們真正保存的是 Set<Int>。
            // get 負責把「index 是否在 Set 裡」轉成 checkbox 狀態。
            get: { selectedIndexes.contains(index) },
            set: { isSelected in
                // set 負責把使用者勾選/取消勾選同步回 Set。
                if isSelected {
                    selectedIndexes.insert(index)
                } else {
                    selectedIndexes.remove(index)
                }
            }
        )
    }
}
