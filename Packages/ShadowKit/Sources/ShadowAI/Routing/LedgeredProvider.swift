import Foundation
import OSLog
import ShadowStore
import Synchronization

final class CallJournal: Sendable {
  private struct State {
    var ids: [UUID] = []
    var entries: [ModelCallEntry] = []
    var open = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  var ids: [UUID] { state.withLock { $0.ids } }

  var entries: [ModelCallEntry] { state.withLock { $0.entries } }

  func opened() {
    state.withLock { $0.open += 1 }
  }

  func closed() {
    let waiters = state.withLock { state in
      state.open -= 1
      guard state.open == 0 else { return [CheckedContinuation<Void, Never>]() }
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters { waiter.resume() }
  }

  func settled() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let isSettled = state.withLock { state in
        guard state.open > 0 else { return true }
        state.waiters.append(continuation)
        return false
      }
      if isSettled { continuation.resume() }
    }
  }

  func began(_ id: UUID) {
    state.withLock { $0.ids.append(id) }
  }

  func recorded(_ entries: [ModelCallEntry]) {
    state.withLock { $0.entries += entries }
  }
}

struct CallLedger: Sendable {
  let store: VaultStore
  let catalog: ModelCatalog
  let host: String
  let route: ModelRoute
  let now: @Sendable () -> Date
  let makeID: @Sendable () -> UUID
  let journal = CallJournal()

  func start() -> ModelCallStart {
    let millis = Int64((now().timeIntervalSince1970 * 1_000).rounded(.down))
    return ModelCallStart(id: makeID(), provider: host, model: route.model, task: route.task, pace: route.pace, startedMillis: millis)
  }

  func begin(_ call: ModelCallStart) async throws(StoreError) {
    try await store.write { transaction in try Ledger.begin(call, in: &transaction) }
    journal.began(call.id)
  }

  func identify(_ call: ModelCallStart, requestID: String?, generationID: String?) async {
    let outcome = await uncancellable { transaction throws(StoreError) in try Ledger.identify(id: call.id, requestID: requestID, generationID: generationID, in: &transaction) }
    guard case .failure(let failure) = outcome else { return }
    TaskRouter.logger.error("Could not record a call's ids call=\(call.id.uuidString, privacy: .public) code=\(failure.code, privacy: .public)")
  }

  func finish(_ call: ModelCallStart, events: [ModelEvent], endedWith error: ModelError?) async {
    let catalog = catalog
    await close(call) { transaction throws(StoreError) in try Ledger.finish(call, events: events, endedWith: error, catalog: catalog, in: &transaction) }
  }

  func abandon(_ call: ModelCallStart, events: [ModelEvent]) async {
    let catalog = catalog
    await close(call) { transaction throws(StoreError) in try Ledger.abandon(call, events: events, catalog: catalog, in: &transaction) }
  }

  private func close(_ call: ModelCallStart, _ body: @escaping @Sendable (inout WriteTransaction) throws(StoreError) -> [ModelCallEntry]) async {
    switch await uncancellable(body) {
    case .success(let entries):
      journal.recorded(entries)
    case .failure(let failure):
      TaskRouter.logger.error("Could not close a call; its cost stays pending call=\(call.id.uuidString, privacy: .public) code=\(failure.code, privacy: .public)")
    }
  }

  /// Runs apart from the caller's task, so a consumer that stops listening cannot cancel the write.
  private func uncancellable<T: Sendable>(_ body: @escaping @Sendable (inout WriteTransaction) throws(StoreError) -> T) async -> Result<T, StoreError> {
    let store = store
    return await Task { () async -> Result<T, StoreError> in
      do throws(StoreError) {
        return .success(try await store.write { transaction in try body(&transaction) })
      } catch {
        return .failure(error)
      }
    }.value
  }
}

/// Ledgers every stream: `begin` on the first iteration, the ids as soon as they arrive, `finish` after the outcome. A stream cancelled before
/// `finished` is left begun, so its cost stays pending until the provider confirms it, and the attempts it abandoned are written beneath it.
struct LedgeredProvider: ModelProvider {
  let base: any ModelProvider
  let ledger: CallLedger

  /// The stream counts as open from its first `next()`, before its task runs, so `RoutedCall.settled()` cannot pass a stream that is about to begin.
  func stream(_ request: ModelRequest) -> ModelStream {
    let journal = ledger.journal
    return ModelStream(onStart: journal.opened) { continuation throws(ModelError) in
      defer { journal.closed() }
      guard request.model == ledger.route.model else { throw .invalidRequest("The request names a model other than its route's.") }
      let call = ledger.start()
      do throws(StoreError) {
        try await ledger.begin(call)
      } catch {
        if Task.isCancelled { throw .cancelled }
        TaskRouter.logger.error("Did not send a call the ledger could not record code=\(error.code, privacy: .public)")
        throw .notRecorded
      }
      var events: [ModelEvent] = []
      var isIdentified = false
      do throws(ModelError) {
        for try await event in base.stream(request) {
          Self.append(event, to: &events)
          try continuation.yield(event)
          guard !isIdentified, case .started(let requestID, let generationID) = event, requestID != nil || generationID != nil else { continue }
          isIdentified = true
          await ledger.identify(call, requestID: requestID, generationID: generationID)
        }
      } catch {
        let hasFinished = events.contains { if case .finished = $0 { true } else { false } }
        guard hasFinished || (error != .cancelled && !Task.isCancelled) else {
          TaskRouter.logger.notice("A call was cancelled before it finished; its cost stays pending call=\(call.id.uuidString, privacy: .public)")
          await ledger.abandon(call, events: events)
          throw error
        }
        await ledger.finish(call, events: events, endedWith: error)
        throw error
      }
      await ledger.finish(call, events: events, endedWith: nil)
    }
  }

  func validate(_ credential: ProviderCredential) async throws(ModelError) -> CredentialStatus {
    try await base.validate(credential)
  }

  func models() async throws(ModelError) -> [RemoteModel] {
    try await base.models()
  }

  /// Accounting needs only whether text arrived, so consecutive deltas are kept as one empty delta rather than a second copy of the reply.
  private static func append(_ event: ModelEvent, to events: inout [ModelEvent]) {
    switch (event, events.last) {
    case (.textDelta, .textDelta?): return
    case (.textDelta, _): events.append(.textDelta(""))
    default: events.append(event)
    }
  }
}
