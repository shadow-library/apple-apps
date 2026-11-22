import Foundation
import ShadowAI
import ShadowCore
import ShadowNetworking
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowAppShell

nonisolated final class PassCount: Sendable {
  private let value = Mutex(0)

  var count: Int { value.withLock { $0 } }

  func increment() { value.withLock { $0 += 1 } }
}

nonisolated final class PassGate: Sendable {
  private struct State {
    var calls = 0
    var opened: Set<Int> = []
    var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
  }

  private let state = Mutex(State())

  var calls: Int { state.withLock { $0.calls } }

  func enter() async {
    let call = state.withLock { state -> Int in
      state.calls += 1
      return state.calls
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resume = state.withLock { state -> Bool in
        guard !state.opened.contains(call) else { return true }
        state.waiting[call] = continuation
        return false
      }
      if resume { continuation.resume() }
    }
  }

  func open(_ call: Int) {
    let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
      state.opened.insert(call)
      return state.waiting.removeValue(forKey: call)
    }
    continuation?.resume()
  }
}

@MainActor
final class TestClock {
  var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
struct CostWorld {
  static let host = "openrouter.ai"

  let store: VaultStore
  let transport: StubHTTPTransport
  let passes: PassCount

  init(store: VaultStore, transport: StubHTTPTransport = Self.reply(200), passes: PassCount = PassCount()) {
    self.store = store
    self.transport = transport
    self.passes = passes
  }

  init(status: Int = 200) throws {
    self.init(store: try ShellStore.open(), transport: Self.reply(status))
  }

  static func reply(_ status: Int) -> StubHTTPTransport {
    StubHTTPTransport(statusCode: status, json: status == 200 ? "{\"data\":{\"total_cost\":\"0.0005\"}}" : "{}")
  }

  var settler: CostSettler { Self.settler(store: store, transport: transport, passes: passes) }

  func settler(gate: PassGate? = nil, clock: TestClock? = nil) -> CostSettler {
    Self.settler(store: store, transport: transport, passes: passes, gate: gate, clock: clock)
  }

  static func settler(store: VaultStore, transport: StubHTTPTransport, passes: PassCount, gate: PassGate? = nil, clock: TestClock? = nil) -> CostSettler {
    let origin = URL(string: "https://openrouter.ai")
    let lookup = OpenRouterGenerationLookup(
      credential: { () async throws(ModelError) -> ProviderCredential in
        guard let origin, let credential = ProviderCredential(origin: origin, secret: "sk-or-test") else { throw .cancelled }
        return credential
      }, transport: transport)
    let policy = ReconciliationPolicy(maxAttempts: 1, startedGrace: .seconds(0))
    let pass: CostSettler.Pass = { () throws(StoreError) -> ReconciliationReport in
      passes.increment()
      await gate?.enter()
      return try await Ledger.reconcilePending(in: store, using: lookup, policy: policy, sleep: { _ in })
    }
    return CostSettler(clock: { clock?.now ?? Date() }, pass: pass)
  }

  func addPending(generation: String = "gen-1") async throws -> UUID {
    let entry = ModelCallEntry(
      id: UUID(), provider: Self.host, model: "anthropic/claude", task: .chat, pace: nil, startedMillis: 1_700_000_000_000, generationID: generation, outcome: .finished)
    try await store.write { transaction in try Ledger.open(entry, in: &transaction) }
    return entry.id
  }

  func source(of id: UUID) async throws -> LedgerCostSource? {
    try await store.read { transaction in try Ledger.entries(in: transaction).first { $0.id == id }?.costSource }
  }
}

@MainActor
@Suite("Cost settler", TestTimeLimit.standard)
struct CostSettlerTests {
  @Test func shouldPriceALeftoverEntryAtLaunchThroughAScriptedLookup() async throws {
    let world = try CostWorld()
    let id = try await world.addPending()
    let settler = world.settler
    settler.settleLeftovers()
    try await ShellWait.until("the entry is priced") { try await world.source(of: id) == .reported }
    #expect(world.transport.requests.count == 1)
    #expect(world.transport.requests.first?.url?.host == "openrouter.ai")
  }

  @Test func shouldSettleLeftoversOncePerLaunch() async throws {
    let world = try CostWorld()
    let settler = world.settler
    settler.settleLeftovers()
    try await ShellWait.until("the pass ends") { !settler.isSettling }
    settler.settleLeftovers()
    try await Task.sleep(for: .milliseconds(100))
    #expect(world.passes.count == 1)
  }

  @Test func shouldLeaveTheEntryPendingAndNotRetryWhenTheLookupFails() async throws {
    let world = try CostWorld(status: 500)
    let id = try await world.addPending()
    let settler = world.settler
    settler.settle()
    try await ShellWait.until("the pass ends") { !settler.isSettling && world.passes.count == 1 }
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await world.source(of: id) == .pending)
    #expect(world.passes.count == 1 && world.transport.requests.count == 1)
  }

  @Test func shouldCoalesceBurstsOfTriggersIntoAtMostOneFollowUpPass() async throws {
    let world = try CostWorld(status: 500)
    _ = try await world.addPending()
    let settler = world.settler
    for _ in 0..<10 { settler.settle() }
    try await ShellWait.until("the passes end") { !settler.isSettling }
    #expect((1...2).contains(world.passes.count))
  }

  @Test func shouldRunExactlyOneMoreAfterATriggerDuringAPass() async throws {
    let world = try CostWorld()
    let gate = PassGate()
    let settler = world.settler(gate: gate)
    settler.settle()
    try await ShellWait.until("the first pass is in flight") { gate.calls == 1 }
    settler.settle()
    settler.settle()
    gate.open(1)
    try await ShellWait.until("the follow-up pass starts") { gate.calls == 2 }
    gate.open(2)
    try await ShellWait.until("the passes end") { !settler.isSettling }
    try await Task.sleep(for: .milliseconds(100))
    #expect(gate.calls == 2 && world.passes.count == 2)
  }

  @Test func shouldNotLetAShutDownPassClearTheNewPassHandle() async throws {
    let world = try CostWorld()
    let gate = PassGate()
    let settler = world.settler(gate: gate)
    settler.settle()
    try await ShellWait.until("the first pass is in flight") { gate.calls == 1 }
    settler.shutDown()
    #expect(!settler.isSettling)
    settler.settle()
    try await ShellWait.until("the second pass is in flight") { gate.calls == 2 }
    gate.open(1)
    try await Task.sleep(for: .milliseconds(150))
    #expect(settler.isSettling)
    settler.settle()
    gate.open(2)
    try await ShellWait.until("the second pass and its follow-up end") { !settler.isSettling }
  }

  @Test func shouldWaitOutTheCooldownAfterAPassThatPricedNothing() async throws {
    let world = try CostWorld(status: 500)
    _ = try await world.addPending()
    let clock = TestClock()
    let settler = world.settler(clock: clock)
    settler.settle()
    try await ShellWait.until("the first pass ends") { world.passes.count == 1 && !settler.isSettling }

    clock.now.addTimeInterval(59)
    settler.settle()
    try await Task.sleep(for: .milliseconds(100))
    #expect(world.passes.count == 1 && !settler.isSettling)

    clock.now.addTimeInterval(2)
    settler.settle()
    try await ShellWait.until("the pass after the cooldown ends") { world.passes.count == 2 && !settler.isSettling }
    #expect(world.transport.requests.count == 2)
  }

}
