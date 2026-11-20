import Foundation
import ShadowSync
import ShadowSyncRuntime
import ShadowTestSupport
import Testing

@Suite("SyncStartup under storage faults", TestTimeLimit.standard)
struct SyncStartupFaultTests {
  private static let attempts = 200

  private static func settle(_ device: RuntimeDevice) async throws -> SyncStartupResult {
    for _ in 0..<attempts {
      if let result = try? await device.startup.evaluate() { return result }
    }
    throw RuntimeFixtureFailure("evaluation never succeeded under faults")
  }

  @Test("should converge on one vault with one key when two devices start together on hostile storage")
  func convergesUnderFaults() async throws {
    try await forAll(iterations: 100) { generator in
      let keychain = InMemoryKeychain()
      let inner = InMemoryStorageProvider()
      let provider = FaultInjectingStorageProvider(wrapping: inner, seed: generator.next(), plan: .hostile)
      let phone = try RuntimeDevice(keychain.device("phone"), provider: provider)
      let tablet = try RuntimeDevice(keychain.device("tablet"), provider: provider)

      async let phoneResult = Self.settle(phone)
      async let tabletResult = Self.settle(tablet)
      let results = try await [phoneResult, tabletResult]

      let vault = try #require(try await RuntimeFixture.hint(in: inner))
      #expect(results.map { $0.location?.vault } == [vault, vault], "\(results.map(\.phase)) \(provider.faultLog)")
      keychain.deliver()
      provider.setFaultsEnabled(false)
      #expect(try await phone.startup.evaluate().phase == .vault(.ready(vault: vault)))
      #expect(try await tablet.startup.evaluate().phase == .vault(.ready(vault: vault)))
      #expect(try RuntimeFixture.ringKeys(phone.keychain, vault: vault).count == 1)
      #expect(try await inner.listAll(prefix: "").map(\.key) == [VaultPath.hint])
    }
  }
}
