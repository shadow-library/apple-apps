import Foundation
import ShadowCore
import ShadowKeychain
import ShadowSync
import ShadowSyncRuntime
import ShadowTestSupport
import Testing

@Suite("KeyExchangeCoordinator", TestTimeLimit.quick)
struct KeyExchangeCoordinatorTests {
  private struct Pair {
    let provider: InMemoryStorageProvider
    let holder: KeyDevice
    let newcomer: KeyDevice
  }

  private static func pair(keys: [VaultKey], heldFiles: [VaultKey]? = nil, vault: VaultID = KeyFixture.vault) async throws -> Pair {
    let provider = InMemoryStorageProvider()
    let keychain = InMemoryKeychain()
    let holder = try KeyDevice(keychain.device("holder"), vault: vault, provider: provider)
    for key in keys { try holder.ring.add(key) }
    for key in heldFiles ?? keys { try await KeyFixture.putHeldFile(sealedWith: key, vault: vault, in: provider) }
    return Pair(provider: provider, holder: holder, newcomer: try KeyDevice(keychain.device("newcomer"), vault: KeyFixture.vault, provider: provider))
  }

  @Test("should move the ring to a new device once the codes match and the keys open a held file")
  func exchange() async throws {
    let key = KeyFixture.key(1)
    let pair = try await Self.pair(keys: [key])
    let requester = pair.newcomer.exchange().request()
    let responder = try pair.holder.exchange().respond(to: requester.payload)
    #expect(responder.requestID == requester.requestID)

    let code = try requester.receive(responder.payload)
    #expect(code.count == 6 && code.allSatisfy(\.isNumber))
    let imported = try await requester.accept(confirmingCode: responder.revealConfirmationCode())

    #expect(imported.added == [key.id] && imported.unconfirmed.isEmpty && imported.conflicting.isEmpty)
    #expect(pair.newcomer.ring.key(key.id)?.rawBytes == key.rawBytes)
    await #expect(throws: KeyExchangeError.exchangeFinished) { try await requester.accept(confirmingCode: code) }
    #expect(throws: KeyExchangeError.exchangeFinished) { try requester.receive(responder.payload) }
  }

  @Test("should keep the responder's code hidden until it is revealed after the other device scanned")
  func codeOrdering() async throws {
    let pair = try await Self.pair(keys: [KeyFixture.key(1)])
    let requester = pair.newcomer.exchange().request()
    await #expect(throws: KeyExchangeError.awaitingResponse) { try await requester.accept(confirmingCode: "000000") }
    let responder = try pair.holder.exchange().respond(to: requester.payload)
    var dumped = ""
    dump(responder, to: &dumped)
    let hidden = [String(describing: responder), String(reflecting: responder), dumped]
    #expect(!responder.isCodeRevealed)

    let requesterCode = try requester.receive(responder.payload)
    let revealed = responder.revealConfirmationCode()

    #expect(responder.isCodeRevealed && revealed == requesterCode)
    for text in hidden { #expect(!text.contains(revealed)) }
    var dumpedAfter = ""
    dump(responder, to: &dumpedAfter)
    dump(requester, to: &dumpedAfter)
    #expect(!dumpedAfter.contains(revealed))
    #expect(pair.newcomer.ring.keyIDs.isEmpty)
  }

  @Test("should end the exchange with nothing added when the entered code does not match")
  func codeMismatch() async throws {
    let pair = try await Self.pair(keys: [KeyFixture.key(1)])
    let requester = pair.newcomer.exchange().request()
    let responder = try pair.holder.exchange().respond(to: requester.payload)
    let code = try requester.receive(responder.payload)
    let wrong = code == "123456" ? "654321" : "123456"

    await #expect(throws: KeyExchangeError.codeMismatch) { try await requester.accept(confirmingCode: wrong) }
    await #expect(throws: KeyExchangeError.exchangeAborted) { try await requester.accept(confirmingCode: code) }
    #expect(pair.newcomer.ring.keyIDs.isEmpty)
    #expect(try RuntimeFixture.ringKeys(pair.newcomer.keychain, vault: KeyFixture.vault).isEmpty)
  }

  @Test("should refuse a response from someone who saw the request, whose code cannot match the holder's")
  func forgedResponse() async throws {
    let pair = try await Self.pair(keys: [KeyFixture.key(1)])
    let requester = pair.newcomer.exchange().request()
    let attacker = try KeyDevice(InMemoryKeychain().device("attacker"), vault: KeyFixture.vault, provider: pair.provider)
    let planted = KeyFixture.key(0)
    try attacker.ring.add(planted)
    try await KeyFixture.putHeldFile(sealedWith: planted, in: pair.provider)
    let forged = try attacker.exchange().respond(to: requester.payload)
    let genuine = try pair.holder.exchange().respond(to: requester.payload)

    let shown = try requester.receive(forged.payload)
    #expect(throws: KeyExchangeError.envelope(.sessionSpent)) { try requester.receive(genuine.payload) }
    let holderCode = genuine.revealConfirmationCode()
    try #require(shown != holderCode)

    await #expect(throws: KeyExchangeError.codeMismatch) { try await requester.accept(confirmingCode: holderCode) }
    #expect(pair.newcomer.ring.keyIDs.isEmpty)
  }

  @Test("should refuse a replayed request on the holder and a second response on the newcomer")
  func replay() async throws {
    let pair = try await Self.pair(keys: [KeyFixture.key(1)])
    let coordinator = pair.holder.exchange()
    let requester = pair.newcomer.exchange().request()
    let responder = try coordinator.respond(to: requester.payload)

    #expect(throws: KeyExchangeError.requestReplayed) { try coordinator.respond(to: requester.payload) }
    let code = try requester.receive(responder.payload)
    #expect(throws: KeyExchangeError.envelope(.sessionSpent)) { try requester.receive(responder.payload) }
    #expect(try await requester.accept(confirmingCode: code).added == [RuntimeFixture.keyID(1)])
  }

  @Test("should keep waiting after a response to another request, and spend the exchange on a response for another vault")
  func strayResponses() async throws {
    let pair = try await Self.pair(keys: [KeyFixture.key(1)])
    let requester = pair.newcomer.exchange().request()
    let other = pair.newcomer.exchange().request()
    let stray = try pair.holder.exchange().respond(to: other.payload)

    #expect(throws: KeyExchangeError.envelope(.requestMismatch)) { try requester.receive(stray.payload) }
    #expect(throws: KeyExchangeError.envelope(.corruptText)) { try requester.receive("SLX1:not-a-code") }
    let responder = try pair.holder.exchange().respond(to: requester.payload)
    let code = try requester.receive(responder.payload)
    #expect(try await requester.accept(confirmingCode: " \(code.prefix(3)) \(code.dropFirst(3)) ").added == [RuntimeFixture.keyID(1)])

    let foreign = try await Self.pair(keys: [KeyFixture.key(2)], vault: KeyFixture.otherVault)
    let waiting = foreign.newcomer.exchange().request()
    let foreignResponse = try foreign.holder.exchange().respond(to: waiting.payload)
    #expect(throws: KeyExchangeError.envelope(.vaultMismatch(expected: KeyFixture.vault, found: KeyFixture.otherVault))) {
      try waiting.receive(foreignResponse.payload)
    }
    await #expect(throws: KeyExchangeError.exchangeAborted) { try await waiting.accept(confirmingCode: foreignResponse.revealConfirmationCode()) }
    #expect(foreign.newcomer.ring.keyIDs.isEmpty)
  }

  @Test("should never add a received key that opens no held file, and add it on a retry once one exists")
  func keyThatOpensNothing() async throws {
    let (opens, opensNothing) = (KeyFixture.key(1), KeyFixture.key(2))
    let pair = try await Self.pair(keys: [opensNothing], heldFiles: [])
    let requester = pair.newcomer.exchange().request()
    let responder = try pair.holder.exchange().respond(to: requester.payload)
    let code = try requester.receive(responder.payload)

    await #expect(throws: KeyExchangeError.keysUnconfirmed([opensNothing.id])) { try await requester.accept(confirmingCode: code) }
    #expect(pair.newcomer.ring.keyIDs.isEmpty)

    try await KeyFixture.putHeldFile(sealedWith: opensNothing, in: pair.provider)
    #expect(try await requester.accept(confirmingCode: code).added == [opensNothing.id])

    let mixed = try await Self.pair(keys: [opens, opensNothing], heldFiles: [opens])
    let second = mixed.newcomer.exchange().request()
    let answer = try mixed.holder.exchange().respond(to: second.payload)
    let imported = try await second.accept(confirmingCode: try second.receive(answer.payload))
    #expect(imported.added == [opens.id] && imported.unconfirmed == [opensNothing.id])
    #expect(mixed.newcomer.ring.keyIDs == [opens.id])
  }

  @Test("should refuse to answer without a ring key or while the keychain is locked")
  func holderWithoutKeys() async throws {
    let pair = try await Self.pair(keys: [])
    let requester = pair.newcomer.exchange().request()
    #expect(throws: KeyExchangeError.noRingKey) { try pair.holder.exchange().respond(to: requester.payload) }

    let locked = try KeyDevice(InMemoryKeychain().device("locked"), vault: KeyFixture.vault, provider: pair.provider, ringStore: LockedSecureStore())
    #expect(throws: KeyExchangeError.deviceLocked) { try locked.exchange().respond(to: requester.payload) }
    #expect(throws: KeyExchangeError.envelope(.corruptText)) { try pair.holder.exchange().respond(to: "garbage") }
  }

  @Test("should send at most the response's limit, preferring keys at or above the floor")
  func limitsKeys() async throws {
    let keys = (1...20).map(KeyFixture.key)
    let pair = try await Self.pair(keys: keys)
    let requester = pair.newcomer.exchange().request()
    let floor = RuntimeFixture.keyID(10)
    let responder = try pair.holder.exchange().respond(to: requester.payload, floor: floor)
    let imported = try await requester.accept(confirmingCode: try requester.receive(responder.payload))

    let expected = (5...20).map(RuntimeFixture.keyID)
    #expect(imported.added == expected && expected.count == KeyExchangeResponse.maximumKeys)
  }
}
