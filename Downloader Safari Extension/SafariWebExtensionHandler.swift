import AppKit
import SafariServices
import os.log

final class SafariWebExtensionHandler: SFSafariExtensionHandler {
    private struct PendingSafariDownload: Codable {
        let url: String
        let kind: String?
    }

    private let appGroupIdentifier = "group.com.sunnyyu.Downloader"
    private let queueFileName = "pending-safari-downloads.json"
    private let downloadCommand = "download-link"
    private let autoCaptureKey = "automaticallyCaptureSafariDownloads"

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

        enqueueAndOpenDownloader(link, kind: nil)
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

            enqueueAndOpenDownloader(link, kind: userInfo?["kind"] as? String)
            os_log(.default, "Automatically captured Safari download: %@", link)
        case "probe-download":
            guard autoCaptureEnabled(),
                  let requestID = userInfo?["requestID"] as? String,
                  let link = userInfo?["url"] as? String,
                  let url = URL(string: link)
            else { return }

            probeDownload(url) { isTorrent in
                if isTorrent {
                    self.enqueueAndOpenDownloader(link, kind: "torrent")
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

    private func enqueueAndOpenDownloader(_ link: String, kind: String?) {
        enqueueDownload(link, kind: kind)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.sunnyyu.Downloader.addDownload"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        openContainingApp()
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

    private func probeDownload(_ url: URL, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                os_log(.error, "Torrent probe failed for %{public}@: %{public}@", url.absoluteString, error.localizedDescription)
            }

            let isTorrent: Bool
            if let response = response as? HTTPURLResponse {
                let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
                let disposition = response.value(forHTTPHeaderField: "Content-Disposition") ?? ""
                isTorrent = contentType.localizedCaseInsensitiveContains("application/x-bittorrent")
                    || disposition.range(
                        of: #"\.torrent(?:["';\s]|$)"#,
                        options: [.regularExpression, .caseInsensitive]
                    ) != nil
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
                completion(isTorrent)
            }
        }.resume()
    }

    private func enqueueDownload(_ link: String, kind: String?) {
        guard let queueURL = sharedQueueURL() else { return }

        var pending = pendingDownloads(from: queueURL)
        pending.append(PendingSafariDownload(url: link, kind: kind))

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
            return legacyLinks.map { PendingSafariDownload(url: $0, kind: nil) }
        }

        return []
    }
}
