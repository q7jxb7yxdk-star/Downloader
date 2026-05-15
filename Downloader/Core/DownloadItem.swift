import Foundation
import SwiftUI

/// 下載任務的類型。
///
/// App 目前把一般網址下載歸類為 `http`，把 magnet link 或 `.torrent`
/// 檔案歸類為 `torrent`。UI 會根據這個 enum 決定顯示哪個圖示，
/// DownloadManager 也會根據它把任務交給不同 engine。
enum DownloadKind: String, Codable {
    case http
    case torrent

    /// 對應 SF Symbols 名稱，給列表使用。
    var icon: String {
        switch self {
        case .http: "link"
        case .torrent: "dot.radiowaves.left.and.right"
        }
    }
}

/// 下載任務目前所處的狀態。
///
/// 這個狀態會被保存到 `downloads.json`，所以下次開 App 時仍可恢復列表。
enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case unavailable

    /// 顯示在列表上的簡短狀態文字。
    var title: String { rawValue.capitalized }

    /// 狀態顏色集中放在 model，讓 UI 不需要重複判斷。
    var color: Color {
        switch self {
        case .queued: .secondary
        case .downloading: .blue
        case .paused: .orange
        case .completed: .green
        case .failed: .red
        case .unavailable: .secondary
        }
    }
}

/// 一個下載任務的完整資料模型。
///
/// 這個 struct 同時服務三個地方：
/// - UI：顯示名稱、狀態、進度和速度。
/// - Engine：知道 source URL 和 destination folder。
/// - Persistence：透過 `Codable` 存入本機 JSON。
struct DownloadItem: Identifiable, Codable, Hashable {
    /// `Identifiable` 需要穩定 id，Table selection 也是靠它追蹤選中項目。
    var id = UUID()
    var name: String
    var source: URL
    /// 使用者選擇的保存資料夾；nil 時使用 fallback Downloads folder。
    var destination: URL?
    /// 完成後的實際檔案位置。BT 多檔案時可能是保存資料夾。
    var localFileURL: URL?
    var kind: DownloadKind
    var status: DownloadStatus = .queued
    var progress: Double = 0
    var bytesReceived: Int64 = 0
    var bytesExpected: Int64 = 0
    var bytesPerSecond: Int64 = 0
    var averageBytesPerSecond: Int64 = 0
    /// BT 使用：保存使用者選中的 torrent file indexes，方便 App 重開後繼續。
    var selectedTorrentFileIndexes: Set<Int> = []
    /// 軟刪除標記。true 代表顯示在 Trash，而不是立刻從 JSON 移除。
    var isTrashed = false
    /// 從 Trash 還原時用來回復原本狀態。
    var statusBeforeTrash: DownloadStatus?
    /// 失敗訊息；下載中也借用它顯示補充狀態，例如 seeds/peers。
    var errorMessage: String?
    var createdAt = Date()

    /// 明確列出 CodingKeys，方便日後新增欄位時保持向下兼容。
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case source
        case destination
        case localFileURL
        case kind
        case status
        case progress
        case bytesReceived
        case bytesExpected
        case bytesPerSecond
        case averageBytesPerSecond
        case selectedTorrentFileIndexes
        case isTrashed
        case statusBeforeTrash
        case errorMessage
        case createdAt
    }

    /// 手動 init 讓 preview、測試資料、DownloadManager 建立任務時更清楚。
    init(
        id: UUID = UUID(),
        name: String,
        source: URL,
        destination: URL?,
        localFileURL: URL? = nil,
        kind: DownloadKind,
        status: DownloadStatus = .queued,
        progress: Double = 0,
        bytesReceived: Int64 = 0,
        bytesExpected: Int64 = 0,
        bytesPerSecond: Int64 = 0,
        averageBytesPerSecond: Int64 = 0,
        selectedTorrentFileIndexes: Set<Int> = [],
        isTrashed: Bool = false,
        statusBeforeTrash: DownloadStatus? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.destination = destination
        self.localFileURL = localFileURL
        self.kind = kind
        self.status = status
        self.progress = progress
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
        self.bytesPerSecond = bytesPerSecond
        self.averageBytesPerSecond = averageBytesPerSecond
        self.selectedTorrentFileIndexes = selectedTorrentFileIndexes
        self.isTrashed = isTrashed
        self.statusBeforeTrash = statusBeforeTrash
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }

    /// 自訂解碼器的目的，是讓舊版本保存的 JSON 缺少新欄位時仍能讀取。
    ///
    /// 例如 `averageBytesPerSecond` 是後來加入的欄位，舊檔沒有它也不應該令 App crash。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(URL.self, forKey: .source)
        destination = try container.decodeIfPresent(URL.self, forKey: .destination)
        localFileURL = try container.decodeIfPresent(URL.self, forKey: .localFileURL)
        kind = try container.decode(DownloadKind.self, forKey: .kind)
        status = try container.decodeIfPresent(DownloadStatus.self, forKey: .status) ?? .queued
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        bytesReceived = try container.decodeIfPresent(Int64.self, forKey: .bytesReceived) ?? 0
        bytesExpected = try container.decodeIfPresent(Int64.self, forKey: .bytesExpected) ?? 0
        bytesPerSecond = try container.decodeIfPresent(Int64.self, forKey: .bytesPerSecond) ?? 0
        averageBytesPerSecond = try container.decodeIfPresent(Int64.self, forKey: .averageBytesPerSecond) ?? 0
        selectedTorrentFileIndexes = try container.decodeIfPresent(Set<Int>.self, forKey: .selectedTorrentFileIndexes) ?? []
        isTrashed = try container.decodeIfPresent(Bool.self, forKey: .isTrashed) ?? false
        statusBeforeTrash = try container.decodeIfPresent(DownloadStatus.self, forKey: .statusBeforeTrash)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// 列表中顯示的速度文字。
    ///
    /// 下載中顯示即時速度；完成後顯示平均速度；其他狀態用 `-` 代表沒有速度。
    var speedText: String {
        switch status {
        case .downloading:
            return ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .binary) + "/s"
        case .completed where averageBytesPerSecond > 0:
            return "Avg " + ByteCountFormatter.string(fromByteCount: averageBytesPerSecond, countStyle: .binary) + "/s"
        default:
            return "-"
        }
    }

    /// 列表中顯示的狀態文字。
    ///
    /// `errorMessage` 在這個 App 也用來放補充狀態，例如 BT 的 peer/seed 資訊。
    var statusText: String {
        if let errorMessage, !errorMessage.isEmpty {
            switch status {
            case .downloading:
                return errorMessage
            case .failed:
                return "Failed: \(errorMessage)"
            case .unavailable:
                return "Not Available: \(errorMessage)"
            default:
                break
            }
        }
        return status.title
    }
}
