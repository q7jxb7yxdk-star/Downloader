import AppKit
import SafariServices
import os.log

final class SafariWebExtensionHandler: SFSafariExtensionHandler {
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

    private let appGroupIdentifier = "group.com.sunnyyu.Downloader"
    private let queueFileName = "pending-safari-downloads.json"
    private let downloadCommand = "download-link"
    private let autoCaptureKey = "automaticallyCaptureSafariDownloads"
    private let recentDownloadQueue = DispatchQueue(
        label: "com.sunnyyu.Downloader.SafariExtension.RecentDownloads"
    )
    private var recentDownloadDates: [String: Date] = [:]

    override func page(_ page: SFSafariPage, willNavigateTo url: URL?) {
        guard autoCaptureEnabled(),
              let url,
              isDirectDownloadURL(url),
              enqueueAndOpenDownloader(
                  url.absoluteString,
                  kind: url.pathExtension.lowercased() == "torrent" ? "torrent" : nil,
                  name: url.lastPathComponent
              )
        else { return }

        page.getContainingTab { tab in
            tab.close()
        }
        os_log(.default, "Automatically captured direct Safari navigation: %@", url.absoluteString)
    }

    override func validateContextMenuItem(
        withCommand command: String,
        in page: SFSafariPage,
        userInfo: [String: Any]? = nil,
        validationHandler: @escaping (Bool, String?) -> Void
    ) {
        guard command == downloadCommand else {
            validationHandler(true, nil)
            return
        }

        validationHandler(false, nil)
    }

    override func contextMenuItemSelected(
        withCommand command: String,
        in page: SFSafariPage,
        userInfo: [String: Any]? = nil
    ) {
        guard command == downloadCommand,
              let link = userInfo?["url"] as? String,
              !link.isEmpty
        else { return }

        enqueueAndOpenDownloader(link, kind: nil, name: nil)
        os_log(.default, "Queued Safari context menu download: %@", link)
    }

    override func messageReceived(
        withName messageName: String,
        from page: SFSafariPage,
        userInfo: [String: Any]? = nil
    ) {
        switch messageName {
        case "request-auto-capture-setting":
            page.dispatchMessageToScript(
                withName: "auto-capture-setting",
                userInfo: ["enabled": autoCaptureEnabled()]
            )
        case "auto-capture-download":
            guard autoCaptureEnabled(),
                  let link = userInfo?["url"] as? String,
                  !link.isEmpty
            else { return }

            enqueueAndOpenDownloader(link, kind: userInfo?["kind"] as? String, name: nil)
            os_log(.default, "Automatically captured Safari download: %@", link)
        case "probe-download":
            guard autoCaptureEnabled(),
                  let requestID = userInfo?["requestID"] as? String,
                  let link = userInfo?["url"] as? String,
                  let url = URL(string: link)
            else { return }

            probeDownload(url) { isTorrent, fileName in
                if isTorrent {
                    self.enqueueAndOpenDownloader(link, kind: "torrent", name: fileName)
                    os_log(.default, "Automatically captured probed torrent: %@", link)
                }

                page.dispatchMessageToScript(
                    withName: "download-probe-result",
                    userInfo: [
                        "requestID": requestID,
                        "isTorrent": isTorrent
                    ]
                )
            }
        default:
            break
        }
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
        completion: @escaping (Bool, String?) -> Void
    ) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                os_log(.error, "Torrent probe failed for %{public}@: %{public}@", url.absoluteString, error.localizedDescription)
            }

            let isTorrent: Bool
            var fileName: String?
            if let response = response as? HTTPURLResponse {
                let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
                let disposition = response.value(forHTTPHeaderField: "Content-Disposition") ?? ""
                fileName = Self.sanitizedFileName(response.suggestedFilename)
                    ?? Self.fileName(fromContentDisposition: disposition)
                isTorrent = contentType.localizedCaseInsensitiveContains("application/x-bittorrent")
                    || fileName?.lowercased().hasSuffix(".torrent") == true
                os_log(
                    .default,
                    "Torrent probe response %{public}ld for %{public}@; type=%{public}@; disposition=%{public}@",
                    response.statusCode,
                    url.absoluteString,
                    contentType,
                    disposition
                )
            } else {
                isTorrent = false
            }

            DispatchQueue.main.async {
                completion(isTorrent, fileName)
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
