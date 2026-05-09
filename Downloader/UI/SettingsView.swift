import SwiftUI

/// App 設定畫面。
///
/// 這兩個設定目前先保存到 UserDefaults，作為之後實作全域下載佇列和限速功能的基礎。
struct SettingsView: View {
    /// 預計用來限制同時下載任務數。
    @AppStorage("maxConcurrentDownloads") private var maxConcurrentDownloads = 3

    /// 預計用來限制總下載速度；0 代表不限制。
    @AppStorage("speedLimitKBps") private var speedLimitKBps = 0

    var body: some View {
        Form {
            Stepper("Concurrent downloads: \(maxConcurrentDownloads)", value: $maxConcurrentDownloads, in: 1...12)
            Stepper("Speed limit: \(speedLimitKBps == 0 ? "Unlimited" : "\(speedLimitKBps) KB/s")", value: $speedLimitKBps, in: 0...100_000, step: 100)
        }
        .padding(24)
        .frame(width: 420)
    }
}
