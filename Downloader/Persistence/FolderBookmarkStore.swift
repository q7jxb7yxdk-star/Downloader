import Foundation

/// 保存和恢復使用者選擇的下載資料夾。
///
/// macOS sandbox app 不能隨便寫入任意路徑。使用者透過 NSOpenPanel 選過資料夾後，
/// 我們要保存 security-scoped bookmark，下次啟動 App 才能再次取得寫入權限。
enum FolderBookmarkStore {
    private static let bookmarkKey = "lastDownloadFolderBookmark"

    /// 沒有選過資料夾時使用系統 Downloads。
    static var fallbackFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// 讀取上次選擇的資料夾；如果 bookmark 壞了，就回到 Downloads。
    static func lastFolder() -> URL {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return fallbackFolder
        }

        var isStale = false
        do {
            // resolvingBookmarkData 會把保存的 Data 還原成 URL，並附帶 sandbox 權限。
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                // bookmark 可能因資料夾移動等原因變舊，重新保存可更新它。
                save(folder: url)
            }

            return url
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return fallbackFolder
        }
    }

    /// 保存使用者選中的資料夾 bookmark。
    static func save(folder: URL) {
        do {
            let data = try folder.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    /// 在執行檔案操作前臨時打開 security-scoped access。
    ///
    /// 呼叫者只要把需要讀寫的程式碼放進 closure，這裡會自動負責開始和結束存取。
    static func withAccess<T>(to folder: URL, perform work: () throws -> T) rethrows -> T {
        let didStartAccessing = folder.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                folder.stopAccessingSecurityScopedResource()
            }
        }
        return try work()
    }
}
