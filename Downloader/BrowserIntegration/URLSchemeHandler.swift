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
        // URLComponents 會幫我們安全解析 query string，例如：
        // downloader://add?url=https%3A%2F%2Fexample.com%2Ffile.zip
        let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false)
        let value = components?.queryItems?.first(where: { $0.name == "url" })?.value
        // query item 的值仍然只是 String，要再轉成真正 URL；失敗就回 nil。
        return value.flatMap(URL.init(string:))
    }
}
