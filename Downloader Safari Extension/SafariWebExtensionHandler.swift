import AppKit
import SafariServices
import os.log

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let downloadableExtensions: Set<String> = [
        "7z", "aac", "avi", "bin", "bz2", "csv", "dmg", "doc", "docx", "epub",
        "exe", "flac", "gif", "gz", "iso", "jpeg", "jpg", "m4a", "m4v", "mkv",
        "mov", "mp3", "mp4", "msi", "pdf", "pkg", "png", "ppt", "pptx", "rar",
        "tar", "torrent", "tsv", "txt", "wav", "webm", "webp", "xls", "xlsx",
        "xz", "zip"
    ]
    private static let duplicateWindow: TimeInterval = 3

    private struct PendingSafariDownload: Codable {
        let url: String
        let kind: String?
        let name: String?
    }

    private struct DownloadProbeResult {
        let isTorrent: Bool
        let isDownload: Bool
        let fileName: String?
    }

    private let appGroupIdentifier = "group.com.sunny.Downloader"
    private let queueFileName = "pending-safari-downloads.json"
    private let autoCaptureKey = "automaticallyCaptureSafariDownloads"
    private let recentDownloadQueue = DispatchQueue(
        label: "com.sunnyyu.Downloader.SafariExtension.RecentDownloads"
    )
    private var recentDownloadDates: [String: Date] = [:]

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message: Any?
        if #available(macOS 11.0, *) {
            message = request?.userInfo?[SFExtensionMessageKey]
        } else {
            message = request?.userInfo?["message"]
        }

        guard let userInfo = message as? [String: Any],
              let messageName = userInfo["name"] as? String
        else {
            complete(context, response: ["accepted": false])
            return
        }

        switch messageName {
        case "request-auto-capture-setting":
            complete(context, response: [
                "accepted": true,
                "enabled": autoCaptureEnabled()
            ])
        case "auto-capture-download":
            guard autoCaptureEnabled(),
                  let link = userInfo["url"] as? String,
                  !link.isEmpty
            else {
                complete(context, response: [
                    "accepted": false,
                    "enabled": autoCaptureEnabled(),
                    "queued": false
                ])
                return
            }

            let url = URL(string: link)
            let name = (userInfo["displayName"] as? String)
                ?? url.flatMap { Self.downloadableFileName(from: $0) }
            let queued = enqueueAndOpenDownloader(
                link,
                kind: userInfo["kind"] as? String,
                name: name
            )
            os_log(.default, "Automatically captured Safari download: %@", link)
            complete(context, response: [
                "accepted": true,
                "enabled": true,
                "queued": queued
            ])
        case "probe-download":
            guard autoCaptureEnabled(),
                  let requestID = userInfo["requestID"] as? String,
                  let link = userInfo["url"] as? String,
                  let url = URL(string: link)
            else {
                complete(context, response: [
                    "accepted": false,
                    "enabled": autoCaptureEnabled(),
                    "requestID": userInfo["requestID"] as? String ?? "",
                    "isTorrent": false
                ])
                return
            }

            probeDownload(url) { result in
                let queued: Bool
                if result.isTorrent || result.isDownload {
                    queued = self.enqueueAndOpenDownloader(
                        link,
                        kind: result.isTorrent ? "torrent" : nil,
                        name: result.fileName
                    )
                    os_log(.default, "Automatically captured probed download: %@", link)
                } else {
                    queued = false
                }

                var response: [String: Any] = [
                    "accepted": true,
                    "enabled": true,
                    "requestID": requestID,
                    "isTorrent": result.isTorrent,
                    "isDownload": result.isDownload,
                    "queued": queued
                ]
                if let fileName = result.fileName {
                    response["fileName"] = fileName
                }
                self.complete(context, response: response)
            }
        default:
            complete(context, response: ["accepted": false])
            break
        }
    }

    private func complete(_ context: NSExtensionContext, response: [String: Any]) {
        let item = NSExtensionItem()
        if #available(macOS 11.0, *) {
            item.userInfo = [SFExtensionMessageKey: response]
        } else {
            item.userInfo = ["message": response]
        }
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }

    @discardableResult
    private func enqueueAndOpenDownloader(_ link: String, kind: String?, name: String?) -> Bool {
        guard shouldEnqueueDownload(link) else { return false }

        enqueueDownload(link, kind: kind, name: name)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.sunnyyu.Downloader.addDownload"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        openContainingApp()
        return true
    }

    private func isDirectDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https" else { return false }

        let pathExtension = url.pathExtension.lowercased()
        return Self.downloadableExtensions.contains(pathExtension)
            || Self.downloadableFileName(from: url) != nil
    }

    private func shouldEnqueueDownload(_ link: String) -> Bool {
        recentDownloadQueue.sync {
            let now = Date()
            recentDownloadDates = recentDownloadDates.filter {
                now.timeIntervalSince($0.value) < Self.duplicateWindow
            }

            guard let previousDate = recentDownloadDates[link],
                  now.timeIntervalSince(previousDate) < Self.duplicateWindow
            else {
                recentDownloadDates[link] = now
                return true
            }
            return false
        }
    }

    private func openContainingApp() {
        let containingAppURL = Bundle.main.bundleURL
            .deletingLastPathComponent() // PlugIns
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // Downloader.app
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        NSWorkspace.shared.openApplication(
            at: containingAppURL,
            configuration: configuration
        ) { _, error in
            if let error {
                os_log(.error, "Unable to open containing Downloader app: %@", error.localizedDescription)
                self.openDownloaderURLFallback()
            }
        }
    }

    private func openDownloaderURLFallback() {
        guard let activationURL = URL(string: "downloader://authorize") else { return }
        if !NSWorkspace.shared.open(activationURL) {
            os_log(.error, "Unable to open Downloader through URL scheme fallback")
        }
    }

    private func autoCaptureEnabled() -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return true }
        guard defaults.object(forKey: autoCaptureKey) != nil else { return true }
        return defaults.bool(forKey: autoCaptureKey)
    }

    private func probeDownload(
        _ url: URL,
        completion: @escaping (DownloadProbeResult) -> Void
    ) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                os_log(.error, "Download probe failed for %{public}@: %{public}@", url.absoluteString, error.localizedDescription)
            }

            let isTorrent: Bool
            let isDownload: Bool
            var fileName: String?
            if let response = response as? HTTPURLResponse {
                let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
                let disposition = response.value(forHTTPHeaderField: "Content-Disposition") ?? ""
                fileName = Self.sanitizedFileName(response.suggestedFilename)
                    ?? Self.fileName(fromContentDisposition: disposition)
                    ?? response.url.flatMap { Self.downloadablePathFileName(from: $0) }
                isTorrent = contentType.localizedCaseInsensitiveContains("application/x-bittorrent")
                    || fileName?.lowercased().hasSuffix(".torrent") == true
                isDownload = isTorrent
                    || fileName.map(Self.hasDownloadableExtension) == true
                    || Self.isDownloadContentType(contentType)
                os_log(
                    .default,
                    "Download probe response %{public}ld for %{public}@; type=%{public}@; disposition=%{public}@",
                    response.statusCode,
                    url.absoluteString,
                    contentType,
                    disposition
                )
            } else {
                isTorrent = false
                isDownload = false
            }

            DispatchQueue.main.async {
                completion(DownloadProbeResult(isTorrent: isTorrent, isDownload: isDownload, fileName: fileName))
            }
        }.resume()
    }

    private static func fileName(fromContentDisposition disposition: String) -> String? {
        guard !disposition.isEmpty else { return nil }

        if let encodedRange = disposition.range(
            of: #"filename\*\s*=\s*UTF-8''([^;]+)"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let match = String(disposition[encodedRange])
            if let valueStart = match.range(of: "''")?.upperBound {
                let encodedName = String(match[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let decodedName = encodedName.removingPercentEncoding {
                    return sanitizedFileName(decodedName)
                }
            }
        }

        guard let nameRange = disposition.range(
            of: #"filename\s*=\s*(?:"([^"]+)"|([^;]+))"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }

        let match = String(disposition[nameRange])
        guard let equalsIndex = match.firstIndex(of: "=") else { return nil }
        let rawName = match[match.index(after: equalsIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return sanitizedFileName(rawName)
    }

    private static func sanitizedFileName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let repairedName = repairUTF8Mojibake(in: name) ?? name
        let fileName = URL(fileURLWithPath: repairedName).lastPathComponent
        return fileName.isEmpty ? nil : fileName
    }

    private static func downloadableFileName(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let candidates = (components.queryItems ?? []).compactMap { item -> String? in
            let lowerName = item.name.lowercased()
            guard lowerName.contains("filename")
                    || lowerName == "response-content-disposition"
                    || lowerName == "rscd"
                    || lowerName == "content-disposition"
            else { return nil }
            return item.value
        }

        for candidate in candidates {
            let fileName = fileName(fromContentDisposition: candidate)
                ?? sanitizedFileName(candidate)
            if let fileName, hasDownloadableExtension(fileName) {
                return fileName
            }
        }
        return nil
    }

    private static func hasDownloadableExtension(_ fileName: String) -> Bool {
        Self.downloadableExtensions.contains(URL(fileURLWithPath: fileName).pathExtension.lowercased())
    }

    private static func downloadablePathFileName(from url: URL) -> String? {
        guard let fileName = sanitizedFileName(url.lastPathComponent),
              hasDownloadableExtension(fileName)
        else {
            return nil
        }
        return fileName
    }

    private static func isDownloadContentType(_ contentType: String) -> Bool {
        let mediaType = contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return [
            "application/octet-stream",
            "application/x-apple-diskimage",
            "application/x-msdownload",
            "application/zip",
            "application/x-7z-compressed",
            "application/x-rar-compressed",
            "application/pdf"
        ].contains(mediaType)
    }

    private static func repairUTF8Mojibake(in value: String) -> String? {
        guard value.unicodeScalars.contains(where: { $0.value >= 0x80 }),
              let latin1Data = value.data(using: .isoLatin1),
              let repaired = String(data: latin1Data, encoding: .utf8),
              repaired != value
        else {
            return nil
        }

        return repaired
    }

    private func enqueueDownload(_ link: String, kind: String?, name: String?) {
        guard let queueURL = sharedQueueURL() else { return }

        var pending = pendingDownloads(from: queueURL)
        pending.append(PendingSafariDownload(url: link, kind: kind, name: name))

        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }

    private func sharedQueueURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(queueFileName)
    }

    private func pendingDownloads(from queueURL: URL) -> [PendingSafariDownload] {
        guard let data = try? Data(contentsOf: queueURL) else {
            return []
        }

        if let downloads = try? JSONDecoder().decode([PendingSafariDownload].self, from: data) {
            return downloads
        }

        if let legacyLinks = try? JSONDecoder().decode([String].self, from: data) {
            return legacyLinks.map { PendingSafariDownload(url: $0, kind: nil, name: nil) }
        }

        return []
    }
}
