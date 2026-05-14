//
//  SafariWebExtensionHandler.swift
//  Downloader Safari Extension
//
//  Created by Sunny Yu on 10/5/2026.
//

import SafariServices
import os.log

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let appGroupIdentifier = "group.com.sunnyyu.Downloader"
    private let queueFileName = "pending-safari-downloads.json"

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem

        let profile: UUID?
        if #available(iOS 17.0, macOS 14.0, *) {
            profile = request?.userInfo?[SFExtensionProfileKey] as? UUID
        } else {
            profile = request?.userInfo?["profile"] as? UUID
        }

        let message: Any?
        if #available(iOS 15.0, macOS 11.0, *) {
            message = request?.userInfo?[SFExtensionMessageKey]
        } else {
            message = request?.userInfo?["message"]
        }

        os_log(.default, "Received message from browser.runtime.sendNativeMessage: %@ (profile: %@)", String(describing: message), profile?.uuidString ?? "none")

        let didAddDownload: Bool
        if let dictionary = message as? [String: Any],
           dictionary["command"] as? String == "add-download",
           let link = dictionary["url"] as? String {
            enqueueDownload(link)
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.sunnyyu.Downloader.addDownload"),
                object: link,
                userInfo: nil,
                deliverImmediately: true
            )
            didAddDownload = true
        } else {
            didAddDownload = false
        }

        let response = NSExtensionItem()
        if #available(iOS 15.0, macOS 11.0, *) {
            response.userInfo = [ SFExtensionMessageKey: [ "ok": didAddDownload ] ]
        } else {
            response.userInfo = [ "message": [ "ok": didAddDownload ] ]
        }

        context.completeRequest(returningItems: [ response ], completionHandler: nil)
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
