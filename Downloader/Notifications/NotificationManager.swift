import Foundation
import UserNotifications

/// 系統通知管理器。
///
/// 目前只在下載完成時發送一個本地通知。用 singleton 是因為通知中心通常全 App 共用一個入口就夠。
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private init() {
        // 第一次使用時向系統請求通知權限。使用者拒絕也不影響下載功能。
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 發送「下載完成」通知。
    func downloadDidFinish(name: String) {
        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = name

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
