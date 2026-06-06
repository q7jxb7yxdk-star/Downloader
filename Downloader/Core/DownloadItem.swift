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
    var uploadBytesPerSecond: Int64 = 0
    var averageBytesPerSecond: Int64 = 0
    var averageUploadBytesPerSecond: Int64 = 0
    var activeDownloadDuration: TimeInterval = 0
    /// BT 完成後是否仍在 libtorrent session 內提供上載。
    var isTorrentSeeding = false
    /// BT 使用：保存使用者選中的 torrent file indexes，方便 App 重開後繼續。
    var selectedTorrentFileIndexes: Set<Int> = []
    /// BT 使用：保存使用者選中的 torrent 內部路徑，雙擊時可打開內容檔案所在資料夾。
    var selectedTorrentFilePaths: [String] = []
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
        case uploadBytesPerSecond
        case averageBytesPerSecond
        case averageUploadBytesPerSecond
        case activeDownloadDuration
        case isTorrentSeeding
        case selectedTorrentFileIndexes
        case selectedTorrentFilePaths
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
        uploadBytesPerSecond: Int64 = 0,
        averageBytesPerSecond: Int64 = 0,
        averageUploadBytesPerSecond: Int64 = 0,
        activeDownloadDuration: TimeInterval = 0,
        isTorrentSeeding: Bool = false,
        selectedTorrentFileIndexes: Set<Int> = [],
        selectedTorrentFilePaths: [String] = [],
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
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.averageBytesPerSecond = averageBytesPerSecond
        self.averageUploadBytesPerSecond = averageUploadBytesPerSecond
        self.activeDownloadDuration = activeDownloadDuration
        self.isTorrentSeeding = isTorrentSeeding
        self.selectedTorrentFileIndexes = selectedTorrentFileIndexes
        self.selectedTorrentFilePaths = selectedTorrentFilePaths
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
        uploadBytesPerSecond = try container.decodeIfPresent(Int64.self, forKey: .uploadBytesPerSecond) ?? 0
        averageBytesPerSecond = try container.decodeIfPresent(Int64.self, forKey: .averageBytesPerSecond) ?? 0
        averageUploadBytesPerSecond = try container.decodeIfPresent(Int64.self, forKey: .averageUploadBytesPerSecond) ?? 0
        activeDownloadDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .activeDownloadDuration) ?? 0
        isTorrentSeeding = try container.decodeIfPresent(Bool.self, forKey: .isTorrentSeeding) ?? false
        selectedTorrentFileIndexes = try container.decodeIfPresent(Set<Int>.self, forKey: .selectedTorrentFileIndexes) ?? []
        selectedTorrentFilePaths = try container.decodeIfPresent([String].self, forKey: .selectedTorrentFilePaths) ?? []
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
            let downloadText = ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .binary) + "/s"
            guard kind == .torrent else { return downloadText }
            let uploadText = ByteCountFormatter.string(fromByteCount: uploadBytesPerSecond, countStyle: .binary) + "/s"
            return "↓ " + downloadText + "\n↑ " + uploadText
        case .completed where kind == .torrent:
            let downloadText = ByteCountFormatter.string(fromByteCount: averageBytesPerSecond, countStyle: .binary) + "/s"
            let uploadText = ByteCountFormatter.string(fromByteCount: averageUploadBytesPerSecond, countStyle: .binary) + "/s"
            let averageText = "Avg ↓ " + downloadText + "\nAvg ↑ " + uploadText
            guard isTorrentSeeding, uploadBytesPerSecond > 0 else { return averageText }
            let currentUploadText = ByteCountFormatter.string(fromByteCount: uploadBytesPerSecond, countStyle: .binary) + "/s"
            return averageText + "\nNow ↑ " + currentUploadText
        case .completed where averageBytesPerSecond > 0:
            return "Avg " + ByteCountFormatter.string(fromByteCount: averageBytesPerSecond, countStyle: .binary) + "/s"
        default:
            return "-"
        }
    }

    /// 列表中顯示的檔案大小。
    ///
    /// `bytesExpected` 是伺服器或 torrent metadata 提供的總大小；
    /// 如果暫時未知，就以 `-` 表示未知總大小。
    var fileSizeText: String {
        let receivedText = ByteCountFormatter.string(fromByteCount: bytesReceived, countStyle: .binary)

        if bytesExpected > 0 {
            let expectedText = ByteCountFormatter.string(fromByteCount: bytesExpected, countStyle: .binary)
            return receivedText + " / " + expectedText
        }

        if bytesReceived > 0 {
            return receivedText + " / -"
        }

        return "-"
    }

    /// 下載中顯示預計剩餘時間；完成後顯示累計有效下載時間。
    var downloadTimeText: String {
        switch status {
        case .downloading:
            guard bytesExpected > bytesReceived, bytesPerSecond > 0 else { return "-" }
            let remainingBytes = bytesExpected - bytesReceived
            let remainingSeconds = TimeInterval(remainingBytes) / TimeInterval(bytesPerSecond)
            return Self.durationText(remainingSeconds)
        case .completed where activeDownloadDuration > 0:
            return Self.durationText(activeDownloadDuration)
        default:
            return "-"
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }

        return "\(seconds)s"
    }

    /// 列表中顯示的狀態文字。
    ///
    /// `errorMessage` 在這個 App 也用來放補充狀態，例如 BT 的 peer/seed 資訊。
    var statusText: String {
        if status == .completed, kind == .torrent, isTorrentSeeding, uploadBytesPerSecond > 0 {
            return "Completed | Seeding"
        }

        if let errorMessage, !errorMessage.isEmpty {
            switch status {
            case .downloading:
                return errorMessage
            case .completed where kind == .torrent && isTorrentSeeding:
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
