import SafariServices
import os.log

final class SafariWebExtensionHandler: SFSafariExtensionHandler {
    private let appGroupIdentifier = "group.com.sunnyyu.Downloader"
    private let queueFileName = "pending-safari-downloads.json"
    private let downloadCommand = "download-link"

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

        enqueueDownload(link)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.sunnyyu.Downloader.addDownload"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        os_log(.default, "Queued Safari context menu download: %@", link)
    }

    private func enqueueDownload(_ link: String) {
        guard let queueURL = sharedQueueURL() else { return }

        var pending = pendingDownloads(from: queueURL)
        pending.append(link)

        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }

    private func sharedQueueURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(queueFileName)
    }

    private func pendingDownloads(from queueURL: URL) -> [String] {
        guard let data = try? Data(contentsOf: queueURL),
              let links = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }

        return links
    }
}
