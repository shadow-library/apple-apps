import Foundation
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowTestSupport
import Testing

@testable import ShadowSyncRuntime

@Suite("SyncRuntime moves", TestTimeLimit.standard)
struct SyncRuntimeMoveTests {
  private struct Pair {
    let keychain = InMemoryKeychain()
    let old = InMemoryStorageProvider()
    let new = ControlledProvider()
    let phone: RuntimeHarness
    let tablet: RuntimeHarness

    static let newSettings = RuntimeFixture.localFolder("moved")

    init() throws {
      let (old, new) = (old, new)
      let route: @Sendable (SyncProviderSettings) -> any StorageProvider = { $0 == RuntimeFixture.iCloud ? old : new }
      phone = try RuntimeHarness(keychain.device("phone"), makeProvider: route)
      tablet = try RuntimeHarness(keychain.device("tablet"), makeProvider: route)
    }

    static func synced() async throws -> Pair {
      let pair = try Pair()
      await pair.phone.runtime.start()
      await pair.phone.runtime.foreground()
      try await pair.phone.write("phone-early")
      await pair.phone.advance(by: .seconds(60))
      pair.keychain.deliver()
      await pair.tablet.runtime.start()
      await pair.tablet.runtime.foreground()
      await pair.tablet.advance(by: .seconds(60))
      return pair
    }

    func shutdown() async {
      await phone.runtime.shutdown()
      await tablet.runtime.shutdown()
    }
  }

  @Test
  func shouldMoveTheVaultAndLetAnotherDeviceFollowItThroughTheRuntime() async throws {
    let pair = try await Pair.synced()
    #expect(try await pair.tablet.titles()["phone-early"] == "phone-early")
    guard case .moved(_, let location) = try await pair.phone.runtime.moveVault(to: Pair.newSettings) else { throw RuntimeFixtureFailure("the move did not finish") }
    #expect(location.settings == Pair.newSettings)
    await pair.phone.advance(by: .seconds(60))
    #expect(pair.phone.runtime.status == .upToDate)

    await pair.tablet.advance(by: .seconds(60))
    guard case .vaultMoved(let notice) = await pair.tablet.runtime.currentPhase else { throw RuntimeFixtureFailure("the tablet did not see the move") }
    #expect(pair.tablet.runtime.status == .attentionNeeded(.vaultMoved(notice)))
    #expect(notice.targetLocation?.settings == Pair.newSettings)

    guard case .moved = try await pair.tablet.runtime.followMove(to: Pair.newSettings) else { throw RuntimeFixtureFailure("the tablet did not follow") }
    try await pair.tablet.write("tablet-late")
    await pair.tablet.advance(by: .seconds(60))
    await pair.phone.advance(by: .seconds(60))
    #expect(try await pair.phone.titles()["tablet-late"] == "tablet-late")
    #expect(pair.tablet.runtime.status == .upToDate)
    await pair.shutdown()
  }

  @Test
  func shouldHoldSyncWhileAMoveIsUnfinishedAndCarryItOnWhenAskedAgain() async throws {
    let pair = try await Pair.synced()
    pair.new.failPuts(with: .unavailable("offline"))
    await #expect(throws: SyncMoveError.self) { _ = try await pair.phone.runtime.moveVault(to: Pair.newSettings) }
    await pair.phone.advance(by: .seconds(60))
    #expect(await pair.phone.runtime.currentPhase == .moveInProgress)
    #expect(pair.phone.runtime.status == .attentionNeeded(.moveInProgress))
    try await pair.phone.write("phone-during")
    await pair.phone.advance(by: .seconds(60))
    #expect(try await pair.phone.hasPendingChanges())

    pair.new.failPuts(with: nil)
    guard case .moved = try await pair.phone.runtime.moveVault(to: Pair.newSettings) else { throw RuntimeFixtureFailure("the resumed move did not finish") }
    await pair.phone.advance(by: .seconds(60))
    #expect(pair.phone.runtime.status == .upToDate)
    await pair.shutdown()
  }

  @Test
  func shouldLetADeviceStayAtTheOldLocationAfterAMove() async throws {
    let pair = try await Pair.synced()
    _ = try await pair.phone.runtime.moveVault(to: Pair.newSettings)
    await pair.tablet.advance(by: .seconds(60))
    guard case .vaultMoved = await pair.tablet.runtime.currentPhase else { throw RuntimeFixtureFailure("the tablet did not see the move") }
    try await pair.tablet.runtime.stayAfterMove()
    try await pair.tablet.write("tablet-stays")
    await pair.tablet.advance(by: .seconds(60))
    #expect(try await !pair.tablet.hasPendingChanges())
    #expect(pair.tablet.runtime.status == .upToDate)
    await pair.shutdown()
  }
}

extension SyncRuntimeMoveTests {
  @Test
  func shouldDiscardAnUnreadableMoveJournalWhenAskedToAbandonIt() async throws {
    let pair = try await Pair.synced()
    let journal = SyncMoveJournalStore(beside: try pair.phone.directory.locationStore())
    try Data("not a journal".utf8).write(to: journal.url)
    await pair.phone.runtime.foreground()
    await pair.phone.advance(by: .seconds(60))
    #expect(await pair.phone.runtime.currentPhase == .moveInProgress)
    #expect(pair.phone.runtime.status == .attentionNeeded(.moveInProgress))
    try await pair.phone.runtime.abandonMove()
    #expect(!FileManager.default.fileExists(atPath: journal.url.path(percentEncoded: false)))
    try await pair.phone.write("phone-after")
    await pair.phone.advance(by: .seconds(60))
    #expect(try await !pair.phone.hasPendingChanges())
    #expect(pair.phone.runtime.status == .upToDate)
    await pair.shutdown()
  }
}

extension RuntimeHarness {
  func titles() async throws -> [String: String] {
    let notes = try await store.read { try $0.states(ofKind: RuntimeFixture.note) }
    var titles: [String: String] = [:]
    for (ref, state) in notes {
      guard case .record(let record) = state, let title = record[field: "title"]?.value.stringValue else { continue }
      titles[ref.key.rawValue] = title
    }
    return titles
  }
}
