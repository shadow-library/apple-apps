import Foundation
import ShadowNetworking
import ShadowSync

struct GoogleDriveHTTP: Sendable {
  private let session: OAuthSession
  private let transport: any HTTPTransport
  private let trustedHosts: Set<String>

  init(session: OAuthSession, transport: any HTTPTransport, trustedOrigins: [URL]) {
    self.session = session
    self.transport = transport
    trustedHosts = Set(trustedOrigins.compactMap { $0.host(percentEncoded: false)?.lowercased() })
  }

  func isTrusted(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", url.user == nil, url.port == nil || url.port == 443 else { return false }
    guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
    return trustedHosts.contains(host)
  }

  func authorized(_ request: URLRequest) async throws(StorageError) -> (Data, HTTPURLResponse) {
    guard let url = request.url, isTrusted(url) else { throw .underlying("Refusing to send Google credentials to an address outside the Drive API.") }
    let token = try await accessToken()
    let first = try await perform(request, bearer: token)
    guard first.1.statusCode == 401 else { return first }
    let refreshed = try await refreshed(after: token)
    let second = try await perform(request, bearer: refreshed)
    guard second.1.statusCode != 401 else { throw .unauthenticated }
    return second
  }

  func anonymous(_ request: URLRequest) async throws(StorageError) -> (Data, HTTPURLResponse) {
    try await perform(request, bearer: nil)
  }

  private func accessToken() async throws(StorageError) -> OAuthAccessToken {
    do {
      return try await session.accessToken()
    } catch {
      throw GoogleDriveFailure.oauth(error)
    }
  }

  private func refreshed(after rejected: OAuthAccessToken) async throws(StorageError) -> OAuthAccessToken {
    do {
      return try await session.refreshAfterRejection(of: rejected)
    } catch {
      throw GoogleDriveFailure.oauth(error)
    }
  }

  private func perform(_ request: URLRequest, bearer: OAuthAccessToken?) async throws(StorageError) -> (Data, HTTPURLResponse) {
    var request = request
    request.setValue(bearer?.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
    do {
      return try await transport.send(request)
    } catch {
      throw GoogleDriveFailure.transport(error)
    }
  }
}
