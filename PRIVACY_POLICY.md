# Privacy Policy for Downloader

**Effective date:** August 7, 2026

**Last updated:** October 3, 2026

Downloader is a macOS download manager with HTTP/HTTPS, BitTorrent, and Safari Extension features. This Privacy Policy explains what information the app processes, where that processing occurs, and the choices available to you.

## Summary

The developer does not operate a backend service for Downloader and does not collect personal information through the app. Downloader does not contain third-party advertising, analytics, tracking, or crash-reporting SDKs, and the developer does not sell your personal information.

Downloader stores information needed to manage your downloads locally on your Mac. When you start a download or enable a network feature, the app connects directly from your device to the relevant website, download server, BitTorrent peer, tracker, or distributed network. Those third parties may receive network information as described below.

## Information Stored on Your Mac

Downloader may store the following information locally:

- Download URLs, including magnet links
- File names, selected file paths, and download destinations
- Download progress, status, speed, error information, and task history
- A previous valid download-list backup and preserved copies of corrupt download-list data for local recovery
- Torrent metadata and selected torrent file information
- Security-scoped bookmarks that allow continued access to folders you select
- App preferences and Safari Extension settings
- Pending download links passed from the Safari Extension to the app
- Downloaded files and temporary partial-download files

This information is used only to provide download management, resume, file selection, notification, and related app features. It is not sent to the developer.

## Safari Extension

If you install and enable the Downloader Safari Extension, Safari may ask you to allow it to access webpages. With the website access you grant, the extension can inspect links, navigation URLs, filenames, and limited download-related page attributes in order to identify downloadable content, provide the **Download with Downloader** context-menu command, and support automatic download capture.

Processing for these features occurs on your Mac. The extension passes an eligible download URL and related filename information to the Downloader app through Safari native messaging and shared App Group storage. It does not send your general browsing history or webpage contents to the developer.

For certain links whose type is unclear, the extension may make a limited network request to that URL to check response headers and determine whether it is a downloadable file or torrent. You can disable automatic Safari download capture in Downloader's settings, revoke the extension's website access in Safari, or disable the extension entirely.

## Network Connections and Third Parties

Downloader does not proxy downloads through a developer-operated server. Network connections are made directly from your Mac.

When you use HTTP or HTTPS downloading, the destination website or download server may receive information normally included in a network request, such as your IP address, the requested URL, request headers, and transfer activity. The server handles that information under its own privacy practices. HTTPS encrypts traffic in transit; plain HTTP does not.

When you use BitTorrent, Downloader may communicate with peers, trackers, Distributed Hash Table (DHT) nodes, and devices on the local network, and may use router traversal features such as UPnP or NAT-PMP. These participants or services may receive or observe information such as your public IP address, torrent info hash, peer identifier, connection details, and upload or download activity. Completed torrents may continue seeding until you pause or remove them. BitTorrent traffic is not routed through, or collected by, the developer.

Apple's macOS and Safari services may process information as necessary to provide extension hosting, local notifications, file access, and Finder integration. Their handling of information is governed by Apple's applicable terms and privacy policy.

## Data Sharing and Sale

The developer does not receive, sell, rent, or use your personal information for advertising or tracking. Downloader discloses information to network endpoints only as necessary to perform the downloads and network features you choose to use, as described above.

## Retention and Deletion

Local download records remain on your Mac until you remove them. Moving a task to Downloader's Trash does not immediately delete the record or its downloaded files. You can permanently remove a task from Downloader's Trash, and you can choose **Delete with Files** when you also want the associated files moved to the macOS Trash.

The app also keeps one previous valid list snapshot and may preserve corrupt list files for recovery. Removing a task does not immediately remove its record from an older backup or preserved corruption copy. Those files remain local and can be removed separately using Finder after you no longer need them for recovery.

You may separately delete downloaded files, temporary files, app preferences, or other app data using Finder and macOS. Uninstalling the app does not necessarily delete files saved in folders you selected. Because the developer does not receive your app data, there is no developer-held account or personal-data record to delete.

## Security

Downloader uses macOS sandboxing and system file-access controls. However, no method of storage or network transmission is completely secure. The confidentiality of a transfer also depends on the protocol and third-party endpoints involved. You are responsible for choosing trusted download sources and for the content you download or share.

## Children's Privacy

Downloader is not directed to children, and the developer does not knowingly collect personal information from children through the app.

## Changes to This Policy

This Privacy Policy may be updated when Downloader's features or data-handling practices change. The effective date and last-updated date at the top of this page will identify the current version.

## Contact

For privacy questions about Downloader, contact:

**Email:** sonicman212@yahoo.com.hk
