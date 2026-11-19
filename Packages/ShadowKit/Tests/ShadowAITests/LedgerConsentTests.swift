import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import ShadowAI

@Suite("AIConsent", TestTimeLimit.quick)
struct LedgerConsentTests {
  private static let dataClass = "manuscript"

  private static func decide(
    _ state: AIConsentState, provider: String = LedgerFixture.host, dataClass: String = dataClass, summary: String = "v1", at millis: Int64 = 100, in store: VaultStore
  ) async throws {
    try await store.write { transaction in
      try AIConsent.decide(state, provider: provider, dataClass: dataClass, summary: summary, atMillis: millis, in: &transaction)
    }
  }

  private static func granted(_ store: VaultStore, provider: String = LedgerFixture.host, dataClass: String = dataClass, summary: String = "v1") async throws -> Bool {
    try await store.read { try AIConsent.isGranted(provider: provider, dataClass: dataClass, currentSummary: summary, in: $0) }
  }

  private static func record(_ store: VaultStore, provider: String = LedgerFixture.host, dataClass: String = dataClass) async throws -> AIConsentRecord? {
    try await store.read { try AIConsent.record(provider: provider, dataClass: dataClass, in: $0) }
  }

  @Test("should not be granted when never decided")
  func neverDecided() async throws {
    let store = try LedgerFixture.store()
    #expect(try await Self.granted(store) == false)
    #expect(try await Self.record(store) == nil)
  }

  @Test("should be granted after a grant and report the record")
  func granted() async throws {
    let store = try LedgerFixture.store()
    try await Self.decide(.granted, at: 1_234, in: store)
    #expect(try await Self.granted(store))
    #expect(try await Self.record(store) == AIConsentRecord(provider: LedgerFixture.host, dataClass: Self.dataClass, state: .granted, decidedMillis: 1_234, summary: "v1"))
  }

  @Test("should not be granted once revoked")
  func revoked() async throws {
    let store = try LedgerFixture.store()
    try await Self.decide(.granted, at: 1, in: store)
    try await Self.decide(.revoked, at: 2, in: store)
    #expect(try await Self.granted(store) == false)
    #expect(try await Self.record(store)?.state == .revoked)
  }

  @Test("should ask again when the grant was for an older summary")
  func olderSummary() async throws {
    let store = try LedgerFixture.store()
    try await Self.decide(.granted, summary: "v1", in: store)
    #expect(try await Self.granted(store, summary: "v1"))
    #expect(try await Self.granted(store, summary: "v2") == false)
  }

  @Test("should keep decisions per data class and per provider")
  func separateDecisions() async throws {
    let store = try LedgerFixture.store()
    try await Self.decide(.granted, in: store)
    #expect(try await Self.granted(store, dataClass: "memoir") == false)
    #expect(try await Self.granted(store, provider: "other.example.com") == false)
  }

  @Test("should lower-case the host and drop one trailing dot")
  func normalisesHost() async throws {
    let store = try LedgerFixture.store()
    try await Self.decide(.granted, provider: "API.Example.COM.", in: store)
    #expect(try await Self.granted(store, provider: "api.example.com"))
    #expect(try await Self.granted(store, provider: "Api.Example.Com"))
    #expect(try await Self.granted(store, provider: "api.example.com."))
    #expect(try await Self.record(store, provider: "API.EXAMPLE.COM")?.provider == "api.example.com")
  }

  @Test("should strip any number of trailing dots")
  func stripsAllTrailingDots() async throws {
    let store = try LedgerFixture.store()
    try await Self.decide(.granted, provider: "api.example.com", in: store)
    #expect(try await Self.granted(store, provider: "api.example.com.."))
    #expect(try await Self.granted(store, provider: "API.example.com..."))
  }

  @Test("should refuse an empty or blank provider and an empty data class")
  func refusesInvalidIdentity() async throws {
    let store = try LedgerFixture.store()
    await #expect(throws: StoreError.self) { try await Self.decide(.granted, provider: "", in: store) }
    await #expect(throws: StoreError.self) { try await Self.decide(.granted, provider: ".", in: store) }
    await #expect(throws: StoreError.self) { try await Self.decide(.granted, provider: "a b", in: store) }
    await #expect(throws: StoreError.self) { try await Self.decide(.granted, provider: "api.example.com:443", in: store) }
    await #expect(throws: StoreError.self) { try await Self.decide(.granted, provider: "me@api.example.com", in: store) }
    await #expect(throws: StoreError.self) { try await Self.decide(.granted, provider: "api.example.com/v1", in: store) }
    await #expect(throws: StoreError.self) { try await Self.decide(.granted, provider: "bücher.de", in: store) }
    await #expect(throws: StoreError.self) { try await Self.decide(.granted, dataClass: "", in: store) }
  }

  @Test("should converge on the later decision when two devices decide differently")
  func convergesToLater() async throws {
    let clock = LedgerTestClock()
    let first = try LedgerFixture.store(clock)
    let second = try LedgerFixture.store(clock)
    try await Self.decide(.granted, summary: "v1", at: clock.millis, in: first)
    clock.advance()
    try await Self.decide(.revoked, summary: "v2", at: clock.millis, in: second)
    try await LedgerFixture.exchange(first, second)
    for store in [first, second] {
      #expect(try await Self.record(store) == AIConsentRecord(provider: LedgerFixture.host, dataClass: Self.dataClass, state: .revoked, decidedMillis: clock.millis, summary: "v2"))
      #expect(try await Self.granted(store, summary: "v2") == false)
    }
  }

  @Test("should converge on the later decision when the grant is the later one")
  func convergesToLaterGrant() async throws {
    let clock = LedgerTestClock()
    let first = try LedgerFixture.store(clock)
    let second = try LedgerFixture.store(clock)
    try await Self.decide(.revoked, at: clock.millis, in: second)
    clock.advance()
    try await Self.decide(.granted, at: clock.millis, in: first)
    try await LedgerFixture.exchange(first, second)
    #expect(try await Self.granted(first))
    #expect(try await Self.granted(second))
  }

  @Test("should read no record when the stored fields are malformed")
  func malformedRecord() async throws {
    let store = try LedgerFixture.store()
    let key = EntityKey.natural(scope: LedgerProvider.consentScope, kind: LedgerSchema.consentKind, components: [LedgerFixture.host, Self.dataClass])
    try await store.write { transaction in
      _ = try transaction.set(EntityRef(kind: LedgerSchema.consentKind, key: key), ["state": "maybe", "decided": 1, "summary": "v1"])
    }
    #expect(try await Self.record(store) == nil)
    #expect(try await Self.granted(store) == false)
  }
}
