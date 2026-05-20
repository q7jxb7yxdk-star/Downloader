import Foundation

/// 負責把下載列表保存成 JSON。
///
/// 注意：這裡只保存「列表狀態」，不保存 URLSession task 或 libtorrent session。
/// 所以下次開 App 時，進行中的任務會被還原成 paused，避免 UI 顯示正在下載但實際沒有 task。
final class DownloadStore {
    private let fileURL: URL

    init() {
        // Application Support 是 macOS App 保存自身資料的標準位置。
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Downloader", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        fileURL = supportDirectory.appending(path: "downloads.json")
    }

    /// 從 JSON 讀回下載列表。
    func load() -> [DownloadItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let items = (try? JSONDecoder().decode([DownloadItem].self, from: data)) ?? []
        return items.map { item in
            var restored = item
            // App 重開後舊 task 已不存在，所以把下載中狀態改成暫停。
            if restored.status == .downloading {
                restored.status = .paused
                restored.bytesPerSecond = 0
                restored.uploadBytesPerSecond = 0
            }
            return restored
        }
    }

    /// 用 atomic 寫入，避免寫到一半 App 中斷時留下半個 JSON 檔。
    func save(_ items: [DownloadItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
