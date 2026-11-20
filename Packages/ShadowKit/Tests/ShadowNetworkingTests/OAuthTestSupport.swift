import Foundation
import ShadowNetworking
import ShadowTestSupport
import Synchronization
import Testing

final class TestClock: Sendable {
  private let current: Mutex<Date>

  init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
    current = Mutex(date)
  }

  var now: Date { current.withLock { $0 } }

  func advance(by seconds: TimeInterval) {
    current.withLock { $0 = $0.addingTimeInterval(seconds) }
  }
}

actor RequestGates {
  private var opened: Set<Int> = []
  private var waiting: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private(set) var arrivals = 0

  func pass(_ index: Int) async throws {
    arrivals += 1
    if !opened.contains(index) { await withCheckedContinuation { waiting[index, default: []].append($0) } }
    try Task.checkCancellation()
  }

  func open(_ indexes: Int...) {
    for index in indexes {
      opened.insert(index)
      for waiter in waiting.removeValue(forKey: index) ?? [] { waiter.resume() }
    }
  }
}

func eventually(within limit: Duration = .seconds(60), _ condition: () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + limit
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await condition()
}

final class ByteCounter: Sendable {
  private let value = Mutex<UInt8>(0)

  func next() -> UInt8 {
    value.withLock { value in
      defer { value &+= 1 }
      return value
    }
  }
}

enum OAuthFixture {
  static let authorizationEndpoint = URL(string: "https://login.example.com/oauth2/authorize?tenant=common")
  static let tokenEndpoint = URL(string: "https://login.example.com/oauth2/token")
  static let redirectURI = URL(string: "com.example.app:/oauth2redirect")

  static func configuration(
    scopes: [String] = ["files.read", "offline_access"],
    parameters: [String: String] = [:],
    sendsScope: Bool = false
  ) throws -> OAuthClientConfiguration {
    try OAuthClientConfiguration(
      authorizationEndpoint: #require(authorizationEndpoint),
      tokenEndpoint: #require(tokenEndpoint),
      clientID: "client-123",
      redirectURI: #require(redirectURI),
      scopes: scopes,
      additionalAuthorizationParameters: parameters,
      sendsScopeInTokenRequests: sendsScope
    )
  }

  static func client(
    _ transport: StubHTTPTransport,
    clock: TestClock = TestClock(),
    configuration: OAuthClientConfiguration? = nil,
    random: OAuthRandomSource = .system
  ) throws -> OAuthClient {
    OAuthClient(configuration: try configuration ?? self.configuration(), transport: transport, random: random, now: { clock.now })
  }

  static func tokenJSON(access: String, refresh: String? = nil, expiresIn: String? = "3600", scope: String? = nil, type: String = "Bearer") -> String {
    var fields = [#""access_token":"\#(access)""#, #""token_type":"\#(type)""#]
    if let expiresIn { fields.append(#""expires_in":\#(expiresIn)"#) }
    if let refresh { fields.append(#""refresh_token":"\#(refresh)""#) }
    if let scope { fields.append(#""scope":"\#(scope)""#) }
    return "{\(fields.joined(separator: ","))}"
  }

  static func respond(_ request: URLRequest, status: Int = 200, json: String, headers: [String: String] = [:]) throws -> (Data, HTTPURLResponse) {
    try StubHTTPTransport.response(to: request, statusCode: status, data: Data(json.utf8), headers: headers)
  }

  static func form(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    let pairs = body.split(separator: "&").map { pair -> (String, String) in
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).removingPercentEncoding ?? "" }
      return (parts[0], parts.count > 1 ? parts[1] : "")
    }
    return Dictionary(pairs) { first, _ in first }
  }

  static func tokens(access: String = "access-old", refresh: String? = "refresh-old", issuedAt: Date, lifetime: TimeInterval? = 3600) -> OAuthTokens {
    OAuthTokens(accessToken: access, issuedAt: issuedAt, expiresAt: lifetime.map { issuedAt.addingTimeInterval($0) }, refreshToken: refresh, scopes: ["files.read"])
  }

  static func countingRandom() -> OAuthRandomSource {
    let counter = ByteCounter()
    return OAuthRandomSource { count in Array(repeating: counter.next(), count: count) }
  }
}
