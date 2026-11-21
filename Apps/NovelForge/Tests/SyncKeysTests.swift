import Foundation
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowSyncRuntime
import ShadowTestSupport
import SwiftUI
import Testing

@testable import NovelForge

/// One device of a library for the key screens: the app's own wiring over a shared folder, its keychain one device of a shared in-memory keychain, and
/// its own defaults suite for what the screens keep.
@MainActor
struct KeysDevice {
  let world: SyncWorld
  let sync: SyncRuntimes
  let store: VaultStore
  let suite: String
  let defaults: UserDefaults

  private static func launch(_ keychain: InMemoryKeychain.Device, storage: URL?) async throws -> KeysDevice {
    let world = try SyncWorld(keychain: keychain, storage: storage)
    let sync = world.runtimes()
    let (store, clock) = try SyncWorld.openStore()
    await sync.phaseChanged(.active)
    await sync.launch(store, trustedClock: clock)
    let suite = "com.shadow.apps.novelforge.tests.keys.\(UUID().uuidString)"
    return KeysDevice(world: world, sync: sync, store: store, suite: suite, defaults: try #require(UserDefaults(suiteName: suite)))
  }

  /// Creates the library in a new folder and has uploaded a novel, so other devices find files sealed with its key.
  static func holder(_ keychain: InMemoryKeychain, named name: String = "mac", storage: URL? = nil) async throws -> KeysDevice {
    let device = try await launch(keychain.device(name), storage: storage)
    #expect(try await device.runtime.attach(device.world.settings, choice: .create).canSync)
    try await SyncWorld.writeNovel("Ashfall", in: device.store)
    try await SyncWorld.until("the holder has uploaded its novel") { try await SyncWorld.isUploaded(device.store) && device.sync.status == .upToDate }
    return device
  }

  /// Joins the holder's folder with a keychain that has not received the library's key.
  static func newcomer(_ keychain: InMemoryKeychain, joining holder: KeysDevice) async throws -> KeysDevice {
    let device = try await launch(keychain.device("tablet"), storage: holder.world.folder)
    _ = try await device.runtime.attach(device.world.settings, choice: .join(try await holder.vault()))
    try await SyncWorld.until("the newcomer waits for the key") { device.sync.status == .attentionNeeded(.awaitingKey) }
    return device
  }

  var runtime: SyncRuntime {
    get throws { try #require(sync.runtime) }
  }

  var record: RecoveryPhraseRecord { RecoveryPhraseRecord(defaults: defaults) }

  func model() async throws -> SyncKeysModel {
    let model = SyncKeysModel(sync: sync, record: record)
    await model.refresh()
    return model
  }

  func vault() async throws -> VaultID {
    try await runtime.keyServices().vault
  }

  func shutDown() async {
    await sync.shutDown()
    defaults.removePersistentDomain(forName: suite)
    world.remove()
  }
}

@MainActor
@Suite("Sync keys", TestTimeLimit.standard)
struct SyncKeysTests {
  private static func setup(_ model: SyncKeysModel) throws -> RecoveryPhraseSetupModel {
    guard case .setup(let setup)? = model.flow else { throw KeysTestFailure("no setup flow: \(String(describing: model.failure))") }
    return setup
  }

  private static func commit(_ access: SyncKeyAccess) async throws -> (phrase: RecoveryPhrase, outcome: RecoverySetupOutcome) {
    let pending = access.beginRecoveryPhrase()
    let phrase = try #require(pending.phrase)
    let confirmation = Dictionary(uniqueKeysWithValues: pending.confirmationPositions.map { ($0, phrase.words[$0 - 1]) })
    return (phrase, try await access.commitRecoveryPhrase(pending, confirming: confirmation))
  }

  private static func files(under directory: URL) -> [URL] {
    let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    return (walker?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
  }

  @Test func shouldShowTheWordsOnlyUntilConfirmedAndKeepNothingButTheRecipientID() async throws {
    let keychain = InMemoryKeychain()
    let mac = try await KeysDevice.holder(keychain)
    let model = try await mac.model()
    #expect(model.keys?.recovery == .notSetUp)

    await model.startSetup()
    let setup = try Self.setup(model)
    let words = setup.words
    #expect(words.count == 24)
    await setup.confirm()
    #expect(setup.step == .showing)
    setup.wroteDown()
    #expect(setup.words.isEmpty)
    let positions = setup.positions
    #expect(positions.count == 3)
    for position in positions { setup.entries[position] = "wrong" }
    await setup.confirm()

    #expect(setup.step == .confirming && setup.mismatched == positions && setup.failure != nil)
    #expect(try await mac.runtime.keyServices().recoveryStatus() == .notSetUp)
    for position in positions { setup.entries[position] = "  \(words[position - 1].uppercased()) " }
    await setup.confirm()

    guard case .finished = setup.step else { throw KeysTestFailure("setup did not finish: \(setup.step), \(String(describing: setup.failure))") }
    #expect(setup.words.isEmpty && setup.positions.isEmpty && setup.entries.isEmpty)
    guard case .active(let recipient, _) = try await mac.runtime.keyServices().recoveryStatus() else { throw KeysTestFailure("no phrase recorded") }
    let kept = mac.defaults.persistentDomain(forName: mac.suite) ?? [:]
    #expect(kept.keys.sorted() == [RecoveryPhraseRecord.keyPrefix + (try await mac.vault()).rawValue])
    #expect(kept.values.compactMap { $0 as? String } == [recipient])
    let phrase = Data(words.joined(separator: " ").utf8)
    for file in Self.files(under: mac.world.directory) { #expect(try Data(contentsOf: file).firstRange(of: phrase) == nil, "\(file.lastPathComponent)") }

    await model.closeFlow()
    #expect(model.flow == nil && model.notice == .phraseSaved)
    guard case .active? = model.keys?.recovery else { throw KeysTestFailure("the page does not show the phrase: \(String(describing: model.keys))") }
    await mac.shutDown()
  }

  @Test func shouldDropThePhraseWhenSetupIsCancelledOrThePageIsLeft() async throws {
    let mac = try await KeysDevice.holder(InMemoryKeychain())
    let model = try await mac.model()
    await model.startSetup()
    let first = try Self.setup(model)

    await model.closeFlow()

    #expect(first.words.isEmpty && first.positions.isEmpty)
    await model.startSetup()
    let second = try Self.setup(model)
    #expect(second.words.count == 24)
    model.leave()
    #expect(second.words.isEmpty && model.flow == nil)
    #expect(try await mac.runtime.keyServices().recoveryStatus() == .notSetUp)
    #expect(mac.defaults.persistentDomain(forName: mac.suite)?.isEmpty ?? true)
    await mac.shutDown()
  }

  @Test func shouldRecoverByPhraseAndNameWhatIsWrongWithABadOne() async throws {
    let keychain = InMemoryKeychain()
    let mac = try await KeysDevice.holder(keychain)
    let (phrase, outcome) = try await Self.commit(try await mac.runtime.keyServices())
    let tablet = try await KeysDevice.newcomer(keychain, joining: mac)
    let model = try await tablet.model()
    #expect(model.isWaitingForKey)
    await model.startRecovery()
    guard case .recover(let recovery)? = model.flow else { throw KeysTestFailure("no recovery flow") }

    recovery.text = "abandon abandon"
    await recovery.recover()
    #expect(recovery.failure?.detail == RecoveryPhraseError.wrongWordCount(found: 2).code)
    var unknown = phrase.words
    unknown[4] = "notaword"
    recovery.text = unknown.joined(separator: " ")
    await recovery.recover()
    #expect(recovery.failure?.headline == SyncKeysErrors.headline(for: .phrase(.unknownWord(position: 5))))
    recovery.text = RecoveryPhrase(secret: .generate()).words.joined(separator: " ")
    await recovery.recover()
    #expect(recovery.failure?.detail == RecoveryError.noRecoveryCopies.code && recovery.step == .entering)
    #expect(!(try await tablet.runtime.keyServices().holdsKey))

    recovery.text = "\n" + phrase.words.map { $0.uppercased() }.joined(separator: "  \t") + "\n"
    await recovery.recover()

    #expect(recovery.step == .finished(added: 1) && recovery.text.isEmpty && recovery.failure == nil)
    #expect(tablet.record.recipientID(for: try await mac.vault()) == outcome.recipientID)
    await model.closeFlow()
    #expect(model.keys?.holdsKey == true && model.notice == .keyArrived)
    try await SyncWorld.until("the newcomer syncs once the key is here") { tablet.sync.status == .upToDate }
    await tablet.shutDown()
    await mac.shutDown()
  }

  @Test func shouldHideTheHoldersCodeUntilTheOtherDeviceHasScannedAndAddTheKeyOnceTheCodesMatch() async throws {
    let keychain = InMemoryKeychain()
    let mac = try await KeysDevice.holder(keychain)
    let tablet = try await KeysDevice.newcomer(keychain, joining: mac)
    let holding = try await mac.model()
    let waiting = try await tablet.model()
    await waiting.startRequest()
    await holding.startResponse()
    guard case .request(let request)? = waiting.flow, case .respond(let response)? = holding.flow else { throw KeysTestFailure("no exchange flows") }
    guard case .showingRequest(let requestPayload) = request.step else { throw KeysTestFailure("no request code") }

    await response.received(requestPayload)

    guard case .showingResponse(let responsePayload) = response.step else { throw KeysTestFailure("no answer: \(String(describing: response.failure))") }
    #expect(response.code == nil)
    request.received(responsePayload)
    #expect(request.step == .enteringCode)
    #expect(response.code == nil)
    request.code = "12a3"
    #expect(request.code == "123" && !request.canAdd)
    response.otherDeviceScanned()
    let code = try #require(response.code)
    request.code = code
    await request.add()

    #expect(request.step == .finished(added: 1))
    await waiting.closeFlow()
    #expect(waiting.keys?.holdsKey == true)
    await tablet.shutDown()
    await mac.shutDown()
  }

  @Test func shouldEndTheExchangeWithNothingAddedWhenTheCodesDiffer() async throws {
    let keychain = InMemoryKeychain()
    let mac = try await KeysDevice.holder(keychain)
    let tablet = try await KeysDevice.newcomer(keychain, joining: mac)
    let waiting = try await tablet.model()
    await waiting.startRequest()
    guard case .request(let request)? = waiting.flow, case .showingRequest(let payload) = request.step else { throw KeysTestFailure("no request") }
    let responder = try await mac.runtime.keyServices().respond(to: payload)
    request.received(responder.payload)
    let code = responder.revealConfirmationCode()

    request.code = code == "000000" ? "111111" : "000000"
    await request.add()

    guard case .ended(let reason) = request.step else { throw KeysTestFailure("the exchange did not end: \(request.step)") }
    #expect(reason.detail == KeyExchangeError.codeMismatch.code)
    request.code = code
    await request.add()
    #expect(request.step == .ended(reason))
    #expect(!(try await tablet.runtime.keyServices().holdsKey))
    await tablet.shutDown()
    await mac.shutDown()
  }

  @Test func shouldKeepWaitingOnACodeOfTheWrongKindAndEndOnAnotherLibrarysAnswer() async throws {
    let keychain = InMemoryKeychain()
    let mac = try await KeysDevice.holder(keychain)
    let tablet = try await KeysDevice.newcomer(keychain, joining: mac)
    let stranger = try await KeysDevice.holder(InMemoryKeychain(), named: "stranger")
    let waiting = try await tablet.model()
    let holding = try await mac.model()
    await waiting.startRequest()
    await holding.startResponse()
    guard case .request(let request)? = waiting.flow, case .respond(let response)? = holding.flow else { throw KeysTestFailure("no exchange flows") }
    guard case .showingRequest(let payload) = request.step else { throw KeysTestFailure("no request") }

    request.received(payload)
    #expect(request.step == .showingRequest(payload: payload) && request.failure != nil)
    request.received("not a code")
    #expect(request.step == .showingRequest(payload: payload))
    let answer = try await mac.runtime.keyServices().respond(to: try await tablet.runtime.keyServices().requestKeys().payload)
    await response.received(answer.payload)
    #expect(response.step == .awaitingRequest && response.failure?.detail == KeyEnvelopeError.unexpectedKind(2).code)

    let foreign = try await stranger.runtime.keyServices().respond(to: payload)
    request.received(foreign.payload)

    guard case .ended(let reason) = request.step else { throw KeysTestFailure("another library's answer was accepted: \(request.step)") }
    #expect(reason.detail == KeyEnvelopeError.vaultMismatch(expected: try await mac.vault(), found: try await stranger.vault()).code)
    await stranger.shutDown()
    await tablet.shutDown()
    await mac.shutDown()
  }

  @Test func shouldSayWhenAnotherDeviceReplacedThePhraseThisOneSetUp() async throws {
    let keychain = InMemoryKeychain()
    let mac = try await KeysDevice.holder(keychain)
    let model = try await mac.model()
    await model.startSetup()
    let setup = try Self.setup(model)
    let words = setup.words
    setup.wroteDown()
    for position in setup.positions { setup.entries[position] = words[position - 1] }
    await setup.confirm()
    await model.closeFlow()
    guard case .active? = model.keys?.recovery else { throw KeysTestFailure("no phrase set up") }
    let tablet = try await KeysDevice.newcomer(keychain, joining: mac)
    keychain.deliver(to: "tablet")
    try await tablet.deliveredKey()
    let (_, replacement) = try await Self.commit(try await tablet.runtime.keyServices())
    await (try tablet.runtime).localWrite()
    try await SyncWorld.until("the tablet uploads the new phrase") { try await SyncWorld.isUploaded(tablet.store) }

    _ = await mac.sync.changeNotice()
    await model.refresh()

    #expect(model.keys?.recovery == .replaced(byRecipientID: replacement.recipientID))
    await tablet.shutDown()
    await mac.shutDown()
  }

  @Test func shouldFetchTheKeyServicesAgainWhenTheOnesItHeldWentStale() async throws {
    let mac = try await KeysDevice.holder(InMemoryKeychain())
    let vault = try await mac.vault()
    let source = SyncKeyServicesSource(runtime: try mac.runtime)
    let held = try await source.current()
    let model = try await mac.model()
    await model.startSetup()
    let setup = try Self.setup(model)
    let words = setup.words
    let target = try SettingsFolders.make("keys-move")
    defer { try? FileManager.default.removeItem(at: target) }

    _ = try await mac.runtime.moveVault(to: .localFolder(SyncLocalFolderSettings(url: target)))

    await #expect(throws: RecoveryError.self) { try await held.recoveryStatus() }
    let status = try await source.perform(for: vault) { access throws(SyncKeysError) in
      try await SyncKeysError.recovery { () async throws(RecoveryError) in try await access.recoveryStatus() }
    }
    #expect(status == .notSetUp)
    let another = try #require(VaultID("another-vault"))
    await #expect(throws: SyncKeysError.vaultChanged) {
      try await source.perform(for: another) { _ throws(SyncKeysError) in () }
    }
    setup.wroteDown()
    for position in setup.positions { setup.entries[position] = words[position - 1] }
    await setup.confirm()
    guard case .finished = setup.step else { throw KeysTestFailure("setup did not survive the move: \(String(describing: setup.failure))") }
    await mac.shutDown()
  }

  @Test func shouldStopAFlowAndSaySoWhenSyncIsTurnedOffWhileItRuns() async throws {
    let mac = try await KeysDevice.holder(InMemoryKeychain())
    let model = try await mac.model()
    await model.startSetup()
    let setup = try Self.setup(model)

    try await mac.runtime.detach()
    await model.refresh()

    #expect(model.flow == nil && setup.words.isEmpty)
    guard case .flowStopped = model.notice, case .unavailable = model.overview else { throw KeysTestFailure("\(model.overview), \(String(describing: model.notice))") }
    await mac.shutDown()
  }

  @Test func shouldLookForTheKeyAgainWhileWaitingAndLeaveTheWaitingStateWhenItArrives() async throws {
    let keychain = InMemoryKeychain()
    let mac = try await KeysDevice.holder(keychain)
    let tablet = try await KeysDevice.newcomer(keychain, joining: mac)
    let model = try await tablet.model()
    #expect(model.isWaitingForKey)
    let watching = Task { await model.watchForKey(every: .milliseconds(50)) }

    keychain.deliver(to: "tablet")

    try await SyncWorld.until("the waiting page sees the key") { !model.isWaitingForKey }
    #expect(model.notice == .keyArrived)
    await watching.value
    await tablet.shutDown()
    await mac.shutDown()
  }

  @Test func shouldListTheDevicesThatHaveSyncedWithEachKey() async throws {
    let keychain = InMemoryKeychain()
    let mac = try await KeysDevice.holder(keychain)
    let model = try await mac.model()

    let holdings = try #require(model.keys?.holdings)

    #expect(holdings.count == 1)
    #expect(holdings.first?.holders.map(\.replica) == [mac.store.replica])
    #expect(holdings.first?.holders.first?.isThisDevice == true && holdings.first?.holders.first?.name == SyncWorld.device.name)
    await mac.shutDown()
  }

  @Test func shouldOfferAPhraseWhileNoneIsSetUpUntilDeclinedForThatLibrary() async throws {
    let keychain = InMemoryKeychain()
    let mac = try await KeysDevice.holder(keychain)
    let vault = try await mac.vault()
    let offer = RecoveryPhraseOffer(sync: mac.sync, record: mac.record)
    await offer.refresh()
    #expect(offer.vault == vault)

    offer.decline()

    #expect(offer.vault == nil)
    let again = RecoveryPhraseOffer(sync: mac.sync, record: mac.record)
    await again.refresh()
    #expect(again.vault == nil && mac.record.isOfferDeclined(for: vault))
    let elsewhere = try #require(UserDefaults(suiteName: mac.suite + ".other"))
    defer { elsewhere.removePersistentDomain(forName: mac.suite + ".other") }
    let fresh = RecoveryPhraseOffer(sync: mac.sync, record: RecoveryPhraseRecord(defaults: elsewhere))
    await fresh.refresh()
    #expect(fresh.vault == vault)
    _ = try await Self.commit(try await mac.runtime.keyServices())
    await fresh.refresh()
    #expect(fresh.vault == nil)
    let tablet = try await KeysDevice.newcomer(keychain, joining: mac)
    let waiting = RecoveryPhraseOffer(sync: tablet.sync, record: tablet.record)
    await waiting.refresh()
    #expect(waiting.vault == nil)
    await tablet.shutDown()
    await mac.shutDown()
  }

  @Test func shouldOpenStraightIntoPhraseSetupOnlyWhileNoPhraseIsSetUp() async throws {
    let mac = try await KeysDevice.holder(InMemoryKeychain())
    let opened = SyncKeysModel(sync: mac.sync, record: mac.record, start: .phraseSetup)
    await opened.refresh()
    let setup = try Self.setup(opened)
    #expect(setup.words.count == 24)
    await opened.closeFlow()
    #expect(opened.flow == nil)
    _ = try await Self.commit(try await mac.runtime.keyServices())

    let later = SyncKeysModel(sync: mac.sync, record: mac.record, start: .phraseSetup)
    await later.refresh()

    #expect(later.flow == nil)
    await mac.shutDown()
  }

  @Test func shouldKeepWaitingAfterAFailedScanOnlyWhileTheRequestStillAwaitsItsAnswer() throws {
    let vault = try #require(VaultID("vault-scan"))
    let waiting = StubKeyRequest(awaiting: true)
    let model = KeyRequestModel(vault: vault, request: waiting)
    model.received("SLX1:ANSWER")
    #expect(model.step == .showingRequest(payload: waiting.payload) && model.failure?.detail == KeyEnvelopeError.malformed.code)

    let spent = StubKeyRequest(awaiting: false)
    let ended = KeyRequestModel(vault: vault, request: spent)
    ended.received("SLX1:ANSWER")

    guard case .ended(let reason) = ended.step else { throw KeysTestFailure("a spent request kept waiting: \(ended.step)") }
    #expect(reason.detail == KeyEnvelopeError.malformed.code && spent.isCancelled)
  }

  @Test func shouldReportOneReadingOfACodeHeldInFrontOfTheCamera() {
    var debounce = KeyCodeDebounce()
    let start = Date()

    let readings = [
      debounce.accepts("SLX1:A", at: start), debounce.accepts("SLX1:A", at: start.addingTimeInterval(1)), debounce.accepts("SLX1:B", at: start.addingTimeInterval(1.5)),
      debounce.accepts("SLX1:B", at: start.addingTimeInterval(4)),
    ]

    #expect(readings == [true, false, true, true])
  }

  @Test func shouldDrawAQRCodeForTheLongestExchangeText() {
    #expect(KeyCodeRenderer.image(for: "SLX1:" + String(repeating: "A", count: 2_043)) != nil)
  }
}

extension KeysDevice {
  /// Waits until the keychain's delivery has reached this device's runtime.
  func deliveredKey() async throws {
    try await runtime.foreground()
    try await SyncWorld.until("the delivered key reaches the runtime") { sync.status == .upToDate }
  }
}

/// A request whose every answer fails as malformed, as one can after its session already spent itself on the answer.
final class StubKeyRequest: KeyRequesting {
  let payload = "SLX1:REQUEST"
  let isAwaitingResponse: Bool
  private(set) var isCancelled = false

  init(awaiting: Bool) {
    isAwaitingResponse = awaiting
  }

  func receive(_ responseText: String) throws(KeyExchangeError) -> String {
    throw .envelope(.malformed)
  }

  func accept(confirmingCode code: String) async throws(KeyExchangeError) -> KeyImport {
    throw .exchangeAborted
  }

  func cancel() {
    isCancelled = true
  }
}

struct KeysTestFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
