import Foundation
import AppKit
import UserNotifications

/// 系統通知管理器。
///
/// 目前只在下載完成時發送一個本地通知。用 singleton 是因為通知中心通常全 App 共用一個入口就夠。
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() {
        super.init()

        // App 在前景時，macOS 預設可能不彈出通知。
        // 把 delegate 設成自己，下面的 willPresent 會明確要求顯示 banner 和播放聲音。
        UNUserNotificationCenter.current().delegate = self
        // 第一次使用時向系統請求通知權限。使用者拒絕也不影響下載功能。
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 發送「下載完成」通知。
    func downloadDidFinish(name: String) {
        // 播放 macOS 系統提示音，也就是使用者熟悉的「叮」。
        NSSound.beep()

        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = name
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("Notification failed: \(error.localizedDescription)")
            }
        }
    }

    /// App 在前景時也顯示通知。
    ///
    /// 沒有這個 delegate callback 時，通知常常只進 Notification Center，
    /// 使用者正在看 app 時反而看不到彈出 banner。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// 使用者點擊通知時，只把現有 Downloader 視窗帶到前面。
    ///
    /// 這樣通知仍然有反應，但不會因為點擊通知而額外開一個 Downloader 視窗。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
        }
    }
}
