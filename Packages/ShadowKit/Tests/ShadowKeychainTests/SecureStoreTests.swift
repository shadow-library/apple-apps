import Foundation
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
}
