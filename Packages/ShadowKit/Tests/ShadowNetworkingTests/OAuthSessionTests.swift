import Foundation
import ShadowNetworking
import ShadowTestSupport
import Testing

@Suite("OAuthSession", TestTimeLimit.quick)
struct OAuthSessionTests {
  private struct Harness {
    let clock = TestClock()
    let transport: StubHTTPTransport
    let store: InMemoryOAuthTokenStore
    let session: OAuthSession

    init(
      age: TimeInterval?,
      lifetime: TimeInterval = 3600,
      gates: RequestGates? = nil,
      respond: @escaping @Sendable (URLRequest, Int) throws -> (Data, HTTPURLResponse)
    ) throws {
      let counter = RequestCounter()
      transport = StubHTTPTransport { request in
        let index = counter.next()
        try await gates?.pass(index)
        return try respond(request, index)
      }
      let now = clock.now
      store = InMemoryOAuthTokenStore(tokens: age.map { OAuthFixture.tokens(issuedAt: now.addingTimeInterval(-$0), lifetime: lifetime) })
      session = OAuthSession(client: try OAuthFixture.client(transport, clock: clock), store: store)
    }

    init(age: TimeInterval?, lifetime: TimeInterval = 3600, gates: RequestGates? = nil) throws {
      try self.init(age: age, lifetime: lifetime, gates: gates) { request, index in
        try OAuthFixture.respond(request, json: OAuthFixture.tokenJSON(access: "access-\(index)", refresh: "refresh-\(index)"))
      }
    }
  }

  private final class RequestCounter: Sendable {
    private let counter = ByteCounter()

    func next() -> Int { Int(counter.next()) + 1 }
  }

  @Test("should hand out the stored token without a request while it is fresh")
  func returnsFreshToken() async throws {
    let harness = try Harness(age: 0)

    let token = try await harness.session.accessToken()

    #expect(token.value == "access-old")
    #expect(token.authorizationHeaderValue == "Bearer access-old")
    #expect(harness.transport.requests.isEmpty)
  }

  @Test("should report that no account is signed in when the store is empty")
  func reportsNotSignedIn() async throws {
    let harness = try Harness(age: nil)

    await #expect(throws: OAuthError.notSignedIn) { try await harness.session.accessToken() }
  }

  @Test("should refresh within the margin before expiry and persist the rotated tokens before returning")
  func refreshesWithinMargin() async throws {
    let harness = try Harness(age: 3500)

    let token = try await harness.session.accessToken()

    #expect(token.value == "access-1")
    #expect(await harness.store.tokens?.accessToken == "access-1")
    #expect(await harness.store.tokens?.refreshToken == "refresh-1")
    #expect(harness.transport.requests.count == 1)
  }

  @Test("should not refresh a token outside the margin")
  func keepsTokenOutsideMargin() async throws {
    let harness = try Harness(age: 3400)

    #expect(try await harness.session.accessToken().value == "access-old")
    #expect(harness.transport.requests.isEmpty)
  }

  @Test("should shrink the margin to half the lifetime of a short-lived token")
  func clampsMarginForShortLifetimes() async throws {
    let harness = try Harness(age: 0, lifetime: 60)

    harness.clock.advance(by: 29)
    #expect(try await harness.session.accessToken().value == "access-old")
    harness.clock.advance(by: 1)
    #expect(try await harness.session.accessToken().value == "access-1")
    #expect(harness.transport.requests.count == 1)
  }

  @Test("should share one refresh among concurrent callers")
  func singleFlightRefresh() async throws {
    let harness = try Harness(age: 4000)

    let values = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<25 { group.addTask { try await harness.session.accessToken().value } }
      return try await group.reduce(into: [String]()) { $0.append($1) }
    }

    #expect(Set(values) == ["access-1"])
    #expect(harness.transport.requests.count == 1)
    #expect(await harness.store.saved.count == 1)
  }

  @Test("should refresh once for every concurrent caller rejected with the same token, and once more for the next token")
  func forcesRefreshOncePerToken() async throws {
    let harness = try Harness(age: 0)
    let rejected = try await harness.session.accessToken()

    let values = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<25 { group.addTask { try await harness.session.refreshAfterRejection(of: rejected).value } }
      return try await group.reduce(into: [String]()) { $0.append($1) }
    }
    let late = try await harness.session.refreshAfterRejection(of: rejected)
    let next = try await harness.session.refreshAfterRejection(of: late)

    #expect(Set(values) == ["access-1"])
    #expect(late.value == "access-1")
    #expect(next.value == "access-2")
    #expect(harness.transport.requests.count == 2)
  }

  @Test("should ask for a new sign-in when a forced refresh returns the rejected token, without asking again")
  func stopsWhenRefreshReturnsSameToken() async throws {
    let harness = try Harness(age: 0) { request, _ in
      try OAuthFixture.respond(request, json: OAuthFixture.tokenJSON(access: "access-old"))
    }
    let rejected = try await harness.session.accessToken()

    await #expect(throws: OAuthError.reauthorizationRequired) { try await harness.session.refreshAfterRejection(of: rejected) }
    await #expect(throws: OAuthError.reauthorizationRequired) { try await harness.session.refreshAfterRejection(of: rejected) }
    #expect(harness.transport.requests.count == 1)
  }

  @Test("should ask for a new sign-in on an invalid grant and not retry the dead refresh token")
  func stopsOnInvalidGrant() async throws {
    let harness = try Harness(age: 4000) { request, _ in
      try OAuthFixture.respond(request, status: 400, json: #"{"error":"invalid_grant"}"#)
    }

    await #expect(throws: OAuthError.reauthorizationRequired) { try await harness.session.accessToken() }
    await #expect(throws: OAuthError.reauthorizationRequired) { try await harness.session.accessToken() }
    #expect(harness.transport.requests.count == 1)
    #expect(await harness.store.tokens?.refreshToken == "refresh-old")
  }

  @Test("should adopt tokens another process stored after its own refresh token was refused")
  func adoptsTokensRotatedElsewhere() async throws {
    let harness = try Harness(age: 4000) { request, index in
      guard OAuthFixture.form(request)["refresh_token"] == "refresh-elsewhere" else { return try OAuthFixture.respond(request, status: 400, json: #"{"error":"invalid_grant"}"#) }
      return try OAuthFixture.respond(request, json: OAuthFixture.tokenJSON(access: "access-\(index)"))
    }
    await #expect(throws: OAuthError.reauthorizationRequired) { try await harness.session.accessToken() }

    await harness.store.replace(with: OAuthFixture.tokens(access: "access-elsewhere", refresh: "refresh-elsewhere", issuedAt: harness.clock.now.addingTimeInterval(-4000)))
    let token = try await harness.session.accessToken()

    #expect(token.value == "access-2")
    #expect(await harness.store.tokens?.refreshToken == "refresh-elsewhere")
    #expect(harness.transport.requests.count == 2)
  }

  @Test("should keep rotated tokens in memory when saving fails and save them before the next hand-out")
  func retriesFailedSave() async throws {
    let harness = try Harness(age: 4000)
    await harness.store.failNextSave(with: .tokenStorage("locked"))

    await #expect(throws: OAuthError.tokenStorage("locked")) { try await harness.session.accessToken() }
    #expect(await harness.store.tokens?.accessToken == "access-old")
    let token = try await harness.session.accessToken()

    #expect(token.value == "access-1")
    #expect(await harness.store.tokens?.refreshToken == "refresh-1")
    #expect(harness.transport.requests.count == 1)
  }

  @Test("should keep retryable refresh failures retryable and try again on the next call")
  func retriesAfterOutage() async throws {
    let harness = try Harness(age: 4000) { request, index in
      guard index > 1 else { return try OAuthFixture.respond(request, status: 503, json: "") }
      return try OAuthFixture.respond(request, json: OAuthFixture.tokenJSON(access: "access-\(index)"))
    }

    await #expect(throws: OAuthError.serviceUnavailable(status: 503, retryAfter: nil)) { try await harness.session.accessToken() }
    #expect(try await harness.session.accessToken().value == "access-2")
    #expect(await harness.store.tokens?.refreshToken == "refresh-old")
  }

  @Test("should drop a refresh that answers after sign-out")
  func dropsRefreshAfterSignOut() async throws {
    let clock = TestClock()
    let (gate, opener) = AsyncStream<Void>.makeStream()
    let (arrivals, arrived) = AsyncStream<Void>.makeStream()
    let transport = StubHTTPTransport { request in
      arrived.yield()
      for await _ in gate { break }
      return try OAuthFixture.respond(request, json: OAuthFixture.tokenJSON(access: "late", refresh: "late"))
    }
    let store = InMemoryOAuthTokenStore(tokens: OAuthFixture.tokens(issuedAt: clock.now.addingTimeInterval(-4000)))
    let session = OAuthSession(client: try OAuthFixture.client(transport, clock: clock), store: store)
    let pending = Task { try await session.accessToken() }
    for await _ in arrivals { break }

    try await session.signOut()
    opener.yield()

    await #expect(throws: OAuthError.notSignedIn) { try await pending.value }
    #expect(await store.tokens == nil)
    await #expect(throws: OAuthError.notSignedIn) { try await session.accessToken() }
  }

  @Test("should hand the signed-in tokens to callers waiting on a refresh that answers after the sign-in")
  func dropsRefreshAfterSignIn() async throws {
    let gates = RequestGates()
    let harness = try Harness(age: 4000, gates: gates)
    let fresh = OAuthFixture.tokens(access: "access-signed-in", refresh: "refresh-signed-in", issuedAt: harness.clock.now)
    let waiting = Task { try await harness.session.accessToken().value }
    #expect(await eventually { await gates.arrivals == 1 })

    try await harness.session.signIn(with: fresh)
    await gates.open(1)

    #expect(try await waiting.value == "access-signed-in")
    #expect(try await harness.session.accessToken().value == "access-signed-in")
    #expect(await harness.store.tokens == fresh)
    #expect(await harness.store.saved.map(\.accessToken) == ["access-signed-in"])
    #expect(harness.transport.requests.count == 1)
  }

  @Test("should not let a refresh from before a sign-in end the refresh that started after it")
  func keepsNewerRefreshInFlight() async throws {
    let gates = RequestGates()
    let harness = try Harness(age: 4000, gates: gates)
    let expired = OAuthFixture.tokens(access: "access-signed-in", refresh: "refresh-signed-in", issuedAt: harness.clock.now.addingTimeInterval(-4000))
    let first = Task { try await harness.session.accessToken().value }
    #expect(await eventually { await gates.arrivals == 1 })
    try await harness.session.signIn(with: expired)
    let second = Task { try await harness.session.accessToken().value }
    #expect(await eventually { await gates.arrivals == 2 })

    await gates.open(1)
    _ = await eventually(within: .milliseconds(300)) { await gates.arrivals > 2 }
    await gates.open(2, 3)

    #expect(try await first.value == "access-2")
    #expect(try await second.value == "access-2")
    #expect(harness.transport.requests.count == 2)
    #expect(OAuthFixture.form(harness.transport.requests[1])["refresh_token"] == "refresh-signed-in")
    #expect(await harness.store.saved.map(\.accessToken) == ["access-signed-in", "access-2"])
  }

  @Test("should leave the store empty when signing out while rotated tokens are being saved")
  func signsOutDuringSave() async throws {
    let harness = try Harness(age: 4000)
    await harness.store.holdSaves()
    let refreshing = Task { try await harness.session.accessToken() }
    #expect(await eventually { await harness.store.heldSaveCount == 1 })

    let signingOut = Task { try await harness.session.signOut() }
    _ = await eventually(within: .milliseconds(300)) { await harness.store.clearCount > 0 }
    await harness.store.releaseSaves()

    try await signingOut.value
    await #expect(throws: OAuthError.notSignedIn) { try await refreshing.value }
    #expect(await harness.store.tokens == nil)
    await #expect(throws: OAuthError.notSignedIn) { try await harness.session.accessToken() }
  }

  @Test("should finish and save a shared refresh when one of its waiters is cancelled")
  func survivesCancelledWaiter() async throws {
    let gates = RequestGates()
    let harness = try Harness(age: 4000, gates: gates)
    let cancelled = Task { try await harness.session.accessToken().value }
    #expect(await eventually { await gates.arrivals == 1 })
    let waiting = Task { try await harness.session.accessToken().value }

    cancelled.cancel()
    await gates.open(1)

    #expect(try await waiting.value == "access-1")
    #expect(await harness.store.tokens?.refreshToken == "refresh-1")
    #expect(harness.transport.requests.count == 1)
  }

  @Test("should keep handing out an unexpired token while a refresh ahead of expiry fails with a retryable error")
  func fallsBackDuringOutage() async throws {
    let harness = try Harness(age: 3500) { request, _ in try OAuthFixture.respond(request, status: 503, json: "") }

    #expect(try await harness.session.accessToken().value == "access-old")
    harness.clock.advance(by: 100)
    await #expect(throws: OAuthError.serviceUnavailable(status: 503, retryAfter: nil)) { try await harness.session.accessToken() }
    #expect(harness.transport.requests.count == 2)
  }

  @Test("should save tokens left unsaved before handing them out as the outage fallback")
  func savesBeforeFallingBack() async throws {
    let harness = try Harness(age: 4000) { request, index in
      guard index == 1 else { return try OAuthFixture.respond(request, status: 503, json: "") }
      return try OAuthFixture.respond(request, json: OAuthFixture.tokenJSON(access: "access-1", refresh: "refresh-1"))
    }
    await harness.store.failNextSave(with: .tokenStorage("locked"))
    await #expect(throws: OAuthError.tokenStorage("locked")) { try await harness.session.accessToken() }
    harness.clock.advance(by: 3500)

    let token = try await harness.session.accessToken()

    #expect(token.value == "access-1")
    #expect(await harness.store.tokens?.refreshToken == "refresh-1")
    #expect(harness.transport.requests.count == 2)
  }

  @Test("should not fall back to an unexpired token when the refresh is refused for good")
  func throwsOnPermanentRefreshFailure() async throws {
    let harness = try Harness(age: 3500) { request, _ in try OAuthFixture.respond(request, status: 400, json: #"{"error":"invalid_grant"}"#) }

    await #expect(throws: OAuthError.reauthorizationRequired) { try await harness.session.accessToken() }
  }

  @Test("should save tokens on sign-in and forget them on sign-out")
  func signsInAndOut() async throws {
    let harness = try Harness(age: nil)

    try await harness.session.signIn(with: OAuthFixture.tokens(access: "fresh", issuedAt: harness.clock.now))
    #expect(try await harness.session.accessToken().value == "fresh")
    #expect(await harness.store.tokens?.accessToken == "fresh")
    try await harness.session.signOut()

    #expect(await harness.store.tokens == nil)
    await #expect(throws: OAuthError.notSignedIn) { try await harness.session.accessToken() }
  }
}
