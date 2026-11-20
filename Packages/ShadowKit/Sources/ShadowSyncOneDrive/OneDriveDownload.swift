import Foundation
import ShadowSync

/// Graph answers a content request with a redirect to a short-lived pre-authenticated address; that address gets no bearer token.
enum OneDriveDownload {
  private static let redirects: Set<Int> = [301, 302, 303, 307, 308]

  /// Returns nil when the item does not exist. With `prefix`, asks for the leading bytes only; a download host that ignores the range still yields them.
  static func fetch(_ url: URL, client: GraphClient, prefix: Int? = nil) async throws(StorageError) -> Data? {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    let response = try await client.authorized(request)
    if response.status == 404 { return nil }
    if response.isSuccess { return trim(response.body, to: prefix) }
    guard redirects.contains(response.status) else { throw client.failure(response) }
    guard let location = response.headers["location"].flatMap({ URL(string: $0, relativeTo: url)?.absoluteURL }) else {
      throw .unavailable("OneDrive redirected a download without an address")
    }
    var download = URLRequest(url: location)
    download.httpMethod = "GET"
    if let prefix { download.setValue("bytes=0-\(prefix - 1)", forHTTPHeaderField: "Range") }
    let content = try await client.anonymous(download)
    if content.status == 404 { return nil }
    if [401, 403, 410].contains(content.status) { throw .unavailable("the OneDrive download address was refused") }
    guard content.isSuccess else { throw client.failure(content) }
    return trim(content.body, to: prefix)
  }

  private static func trim(_ data: Data, to prefix: Int?) -> Data {
    guard let prefix else { return data }
    return Data(data.prefix(prefix))
  }
}
