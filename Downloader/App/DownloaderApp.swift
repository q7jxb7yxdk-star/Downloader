import SwiftUI

/// App 入口。
///
/// `@main` 告訴 Swift 這個 struct 是整個 macOS App 的起點。
@main
struct DownloaderApp: App {
    /// 全 App 共用同一個 DownloadManager。
    ///
    /// 用 `@StateObject` 讓它由 App 生命週期持有，不會因畫面重畫而重建。
    @StateObject private var downloadManager = DownloadManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 透過 EnvironmentObject 傳給所有子 View，避免每層手動傳參數。
                .environmentObject(downloadManager)
                .frame(minWidth: 980, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Download...") {
                    // Menu command 不直接持有 ContentView 狀態，所以用 NotificationCenter 叫畫面打開 sheet。
                    NotificationCenter.default.post(name: .showAddDownload, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
        }
    }
}

extension Notification.Name {
    /// 由選單觸發，通知 ContentView 打開新增下載視窗。
    static let showAddDownload = Notification.Name("showAddDownload")
}
