import Foundation

/// 早期預留的 Torrent 管理入口。
///
/// 真正的 BT 下載邏輯已經移到 `TorrentDownloadEngine` 和 `TorrentSessionBridge`。
/// 這個類別目前沒有被核心流程使用，可以視為未來整理/重構時的候選刪除項。
@MainActor
final class TorrentManager {
    static let shared = TorrentManager()

    private init() {}

    func noteTorrentSupportIsPending() {
        // The UI and data model already understand torrent tasks. The engine will
        // be backed by libtorrent through an Objective-C++ bridge in the next pass.
    }
}
