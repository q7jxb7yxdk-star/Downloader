import Foundation
import SwiftUI

enum DownloadKind: String, Codable {
    case http
    case torrent

    var icon: String {
        switch self {
        case .http: "link"
        case .torrent: "dot.radiowaves.left.and.right"
        }
    }
}

enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case unavailable

    var title: String { rawValue.capitalized }

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

struct DownloadItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var source: URL
    var destination: URL?
    var kind: DownloadKind
    var status: DownloadStatus = .queued
    var progress: Double = 0
    var bytesReceived: Int64 = 0
    var bytesExpected: Int64 = 0
    var bytesPerSecond: Int64 = 0
    var errorMessage: String?
    var createdAt = Date()

    var speedText: String {
        guard status == .downloading else { return "-" }
        return ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .binary) + "/s"
    }

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
