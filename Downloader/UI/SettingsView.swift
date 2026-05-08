import SwiftUI

struct SettingsView: View {
    @AppStorage("maxConcurrentDownloads") private var maxConcurrentDownloads = 3
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
