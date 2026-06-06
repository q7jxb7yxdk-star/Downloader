import SwiftUI

/// App 設定畫面。
struct SettingsView: View {
    private static let sharedDefaults = UserDefaults(suiteName: "group.com.sunnyyu.Downloader") ?? .standard

    /// Safari native extension 透過 App Group 讀取同一個設定。
    @AppStorage("automaticallyCaptureSafariDownloads", store: sharedDefaults)
    private var automaticallyCaptureSafariDownloads = true

    /// 預計用來限制同時下載任務數。
    @AppStorage("maxConcurrentDownloads") private var maxConcurrentDownloads = 3

    /// 預計用來限制總下載速度；0 代表不限制。
    @AppStorage("speedLimitKBps") private var speedLimitKBps = 0

    var body: some View {
        Form {
            Toggle("Automatically capture downloads from Safari", isOn: $automaticallyCaptureSafariDownloads)
            Stepper("Concurrent downloads: \(maxConcurrentDownloads)", value: $maxConcurrentDownloads, in: 1...12)
            Stepper("Speed limit: \(speedLimitKBps == 0 ? "Unlimited" : "\(speedLimitKBps) KB/s")", value: $speedLimitKBps, in: 0...100_000, step: 100)
        }
        .padding(24)
        .frame(width: 420)
    }
}
