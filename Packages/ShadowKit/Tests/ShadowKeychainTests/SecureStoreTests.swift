import Foundation
import Security
import ShadowKeychain
import ShadowTestSupport
import Testing

private struct Credentials: Codable, Equatable {
  let accessToken: String
  let refreshToken: String
}

@Suite("SecureStore")
struct SecureStoreTests {
  @Test("should round-trip Codable values")
  func roundTripsCodable() throws {
    let store = InMemorySecureStore()
    let credentials = Credentials(accessToken: "access", refreshToken: "refresh")

    try store.setValue(credentials, forKey: "credentials")

    #expect(try store.value(Credentials.self, forKey: "credentials") == credentials)
  }

  @Test("should round-trip strings and return nil once removed")
  func roundTripsStrings() throws {
    let store = InMemorySecureStore()

    try store.setString("secret", forKey: "token")
    #expect(try store.string(forKey: "token") == "secret")

    try store.removeValue(forKey: "token")
    #expect(try store.string(forKey: "token") == nil)
  }

  @Test("should throw decoding when stored data does not match the requested type")
  func throwsOnMismatchedType() throws {
    let store = InMemorySecureStore(["credentials": Data("not json".utf8)])

    let error = #expect(throws: SecureStoreError.self) { try store.value(Credentials.self, forKey: "credentials") }

    guard case .decoding = error else {
      Issue.record("Unexpected error \(String(describing: error))")
      return
    }
  }

  @Test("should insert once and never overwrite an existing value")
  func insertsOnce() throws {
    let store = InMemorySecureStore()

    #expect(try store.insertString("first", forKey: "token"))
    #expect(try store.insertString("second", forKey: "token") == false)
    #expect(try store.string(forKey: "token") == "first")

    let credentials = Credentials(accessToken: "access", refreshToken: "refresh")
    #expect(try store.insertValue(credentials, forKey: "credentials"))
    #expect(try store.insertValue(Credentials(accessToken: "other", refreshToken: "other"), forKey: "credentials") == false)
    #expect(try store.value(Credentials.self, forKey: "credentials") == credentials)
  }

  @Test("should insert again once the value is removed")
  func insertsAfterRemoval() throws {
    let store = InMemorySecureStore(["token": Data("first".utf8)])

    try store.removeValue(forKey: "token")

    #expect(try store.insertString("second", forKey: "token"))
    #expect(try store.string(forKey: "token") == "second")
  }

  @Test("should list every key and none for an unused store")
  func listsKeys() throws {
    let store = InMemorySecureStore()
    #expect(try store.allKeys().isEmpty)

    try store.setString("a", forKey: "b")
    #expect(try store.insertString("a", forKey: "a"))

    #expect(try store.allKeys() == ["a", "b"])
  }

  @Test("should leave exactly one winner when many tasks insert the same key")
  func insertsConcurrently() async throws {
    let store = InMemorySecureStore()

    let winners = await withTaskGroup(of: Int?.self) { group in
      for index in 0..<200 {
        group.addTask { (try? store.insertString("value-\(index)", forKey: "token")) == true ? index : nil }
      }
      return await group.reduce(into: [Int]()) { winners, winner in
        if let winner { winners.append(winner) }
      }
    }

    #expect(winners.count == 1)
    #expect(try store.string(forKey: "token") == winners.first.map { "value-\($0)" })
  }

  @Test("should name a missing entitlement and nothing else as a keychain refusing the build")
  func namesMissingEntitlement() {
    #expect(SecureStoreError.unexpectedStatus(errSecMissingEntitlement).isMissingEntitlement)
    #expect(!SecureStoreError.unexpectedStatus(errSecInteractionNotAllowed).isMissingEntitlement)
    #expect(!SecureStoreError.decoding("x").isMissingEntitlement)
  }
}
