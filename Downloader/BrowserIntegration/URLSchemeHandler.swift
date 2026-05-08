import Foundation

struct URLSchemeHandler {
    static let scheme = "downloader"

    static func downloadURL(from incomingURL: URL) -> URL? {
        guard incomingURL.scheme == scheme else { return nil }
        let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false)
        let value = components?.queryItems?.first(where: { $0.name == "url" })?.value
        return value.flatMap(URL.init(string:))
    }
}
