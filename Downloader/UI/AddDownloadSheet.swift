import SwiftUI
import UniformTypeIdentifiers

/// 新增下載的 sheet。
///
/// 使用者輸入 URL / magnet link，並選擇下載資料夾。
struct AddDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloadManager: DownloadManager

    /// 使用者輸入的原始文字。
    @State private var urlText = ""

    /// 預設使用上次選過的資料夾，讓 App 記住使用者習慣。
    @State private var destination = FolderBookmarkStore.lastFolder()

    /// Add 按鈕是否可用。這裡只做基本 URL 格式檢查。
    private var canAdd: Bool {
        URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Download")
                .font(.title2.bold())

            // SwiftUI 的 TextField 使用雙向 binding：
            // 使用者輸入會改變 urlText；urlText 改變也會反映回畫面。
            TextField("URL or magnet link", text: $urlText)
                .textFieldStyle(.roundedBorder)

            Button {
                chooseTorrentFile()
            } label: {
                Label("Choose .torrent File", systemImage: "doc.badge.plus")
            }
            .help("Choose .torrent File")

            HStack {
                Text(destination.path(percentEncoded: false))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    chooseDestination()
                } label: {
                    Label("Choose Folder", systemImage: "folder")
                }
                .help("Choose Folder")
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .help("Cancel")

                Button("Add") {
                    addDownload()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
                .help("Add")
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    /// 打開 macOS 資料夾選擇器。
    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination

        if panel.runModal() == .OK {
            guard let url = panel.url else { return }
            destination = url
            // 保存 bookmark，之後下載 engine 才能在 sandbox 下寫入這個資料夾。
            FolderBookmarkStore.save(folder: url)
        }
    }

    /// 打開 `.torrent` 檔案選擇器，直接把檔案 URL 交給 BT engine。
    private func chooseTorrentFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]

        if panel.runModal() == .OK {
            guard let url = panel.url else { return }
            // .torrent 檔案本身是本機 URL，但下載內容仍會保存到 destination。
            FolderBookmarkStore.save(folder: destination)
            downloadManager.add(url: url, destination: destination)
            dismiss()
        }
    }

    /// 建立下載任務，交給 DownloadManager 分派到 HTTP 或 BT engine。
    private func addDownload() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        FolderBookmarkStore.save(folder: destination)
        downloadManager.add(url: url, destination: destination)
        dismiss()
    }
}
