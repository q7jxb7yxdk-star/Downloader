import SwiftUI
import AppKit

/// macOS App delegate，處理 SwiftUI App lifecycle 不容易覆蓋的系統事件。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// App 啟動時檢查是否已有另一個 Downloader 實例。
    ///
    /// macOS 通知點擊有時會透過 LaunchServices 再啟動一次 app。
    /// 如果偵測到同 bundle id 的舊實例，新的實例會立刻退出，避免 Dock 或桌面出現第二個 Downloader。
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        let otherRunningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        if let existingApp = otherRunningApps.first {
            existingApp.activate(options: [.activateAllWindows])
            // URL scheme 可能先開一個新 process，再把 URL 交進來。
            // 稍微延遲退出，避免還沒收到 URL 就把自己關掉。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.terminate(nil)
            }
        }

        bringDownloaderToFront()
    }

    /// Dock 或通知要求重新打開 App 時，只顯示現有視窗。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }

        sender.activate(ignoringOtherApps: true)
        return false
    }

    /// 接收 `downloader://...` URL scheme。
    func application(_ application: NSApplication, open urls: [URL]) {
        bringDownloaderToFront()

        for url in urls {
            Task { @MainActor in
                ExternalDownloadRouter.shared.enqueue(url)
            }
        }
    }

    /// 把 Downloader 視窗帶到最前，避免 URL scheme 只在背景啟動 app。
    @MainActor
    private func bringDownloaderToFront() {
        NSApp.setActivationPolicy(.regular)

        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// 暫存外部 URL，直到 SwiftUI ContentView 已準備好處理。
@MainActor
final class ExternalDownloadRouter {
    static let shared = ExternalDownloadRouter()

    private var pendingURLs: [URL] = []
    private var handler: ((URL) -> Void)?

    private init() {}

    func enqueue(_ url: URL) {
        if let handler {
            handler(url)
        } else {
            pendingURLs.append(url)
        }
    }

    func installHandler(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        let urls = pendingURLs
        pendingURLs.removeAll()
        urls.forEach(handler)
    }

    func removeHandler() {
        handler = nil
    }
}

/// App 入口。
///
/// `@main` 告訴 Swift 這個 struct 是整個 macOS App 的起點。
@main
struct DownloaderApp: App {
    /// 接上 AppKit delegate，讓通知點擊和 Dock reopen 不會建立第二個 App/視窗。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 全 App 共用同一個 DownloadManager。
    ///
    /// 用 `@StateObject` 讓它由 App 生命週期持有，不會因畫面重畫而重建。
    @StateObject private var downloadManager = DownloadManager()

    var body: some Scene {
        Window("Downloader", id: "main") {
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
