import Foundation

/// BT torrent 內的一個檔案。
///
/// `index` 必須保留，因為 libtorrent 選檔案時需要用原始 file index 設定 priority。
struct TorrentFileEntry: Identifiable, Hashable {
    let index: Int
    let path: String
    let size: Int64

    var id: Int { index }
}

/// 傳給 SwiftUI sheet 的 BT 檔案選擇資料。
struct TorrentFileSelection: Identifiable {
    let itemID: DownloadItem.ID
    let title: String
    let files: [TorrentFileEntry]

    var id: DownloadItem.ID { itemID }
}
