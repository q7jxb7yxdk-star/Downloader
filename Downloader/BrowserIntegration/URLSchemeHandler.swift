import Foundation

/// 自訂 URL scheme 的解析工具。
///
/// 之後做 Safari / browser integration 時，可以讓外部用
/// `downloader://?url=https://example.com/file.zip` 叫 App 新增下載。
struct URLSchemeHandler {
    static let scheme = "downloader"

    /// 從 incoming URL 取出真正要下載的 `url` query item。
    static func downloadURL(from incomingURL: URL) -> URL? {
        guard incomingURL.scheme == scheme else { return nil }
        let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false)
        let value = components?.queryItems?.first(where: { $0.name == "url" })?.value
        return value.flatMap(URL.init(string:))
    }
}
