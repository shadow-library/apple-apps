import Foundation
import MemoirCore
import Observation
import ShadowAI
import ShadowAppShell
import ShadowCore
import ShadowJobs
import ShadowStore

/// The consents the Ask screen reads and withdraws for the provider the router sends to; granting goes through the shell's consent sheet.
nonisolated struct InsightConsents: Sendable {
  /// The data classes granted for the configured provider.
  let granted: @Sendable () async throws -> Set<String>
  let withdraw: @Sendable (_ dataClass: String) async throws -> Void

  static func live(ai: AIServices, store: VaultStore) -> InsightConsents {
    InsightConsents(
      granted: {
        let (provider, consents) = await (ai.settings.provider, try ai.grantedConsents(in: store))
        return Set(consents.filter { $0.provider == provider }.map(\.disclosure.dataClass))
      },
      withdraw: { dataClass in
        let provider = await ai.settings.provider
        for consent in try await ai.grantedConsents(in: store) where consent.provider == provider && consent.disclosure.dataClass == dataClass {
          try await ai.revoke(consent, in: store)
        }
      })
  }
}

/// The three kinds of data Memoir asks to send: the call itself, then journal text and health data, each decided on its own.
nonisolated enum AskConsentKind: CaseIterable, Hashable, Sendable {
  case call
  case journal
  case health

  var requirement: AIConsentRequirement {
    switch self {
    case .call: InsightConsent.call
    case .journal: InsightConsent.requirement(for: .journalReflectionReason)
    case .health: InsightConsent.requirement(for: .health)
    }
  }
}

nonisolated enum AskSetup: Equatable, Sendable {
  case checking
  /// No provider ready for a standard call (no key, or OpenRouter without a model for any pace): the screen offers the shell's AI settings.
  case noProvider
  case ready(granted: Set<AskConsentKind>)

  var granted: Set<AskConsentKind> {
    guard case .ready(let granted) = self else { return [] }
    return granted
  }
}

nonisolated struct AskSpend: Equatable, Sendable {
  let summary: SpendSummary
  let limits: SpendLimits
  let decision: SpendDecision
}

nonisolated struct AskBoard: Equatable, Sendable {
  let requests: [InsightRequest]
  let results: [InsightResultEntry]
  let schedule: InsightScheduleRecord?

  static let empty = AskBoard(requests: [], results: [], schedule: nil)

  /// What is waiting or running, else the newest request when it failed and nothing newer was asked, as `activeTask` picks it.
  var active: InsightRequest? {
    if let waiting = requests.first(where: { $0.status == .queued || $0.status == .running }) { return waiting }
    guard let newest = requests.first, case .failed = newest.status else { return nil }
    return newest
  }

  func request(for result: InsightResultEntry) -> InsightRequest? {
    requests.first { $0.resultID == result.id }
  }
}

enum AskNotice: Equatable {
  case queued
  case waitingForSpend(SpendDecision)
  case alreadyRunning
  case cancelled
  case failure(PresentedError)
}

/// The Ask screen: one question at a time about the owner's own data, answered on this device while the app is open. Nothing here issues a command;
/// a suggestion is a link to the screen where the owner makes the change by hand.
@MainActor
@Observable
final class AskModel {
  var question = ""
  private(set) var board = Loadable<AskBoard>.loading
  private(set) var setup = AskSetup.checking
  private(set) var spend: AskSpend?
  private(set) var isSubmitting = false
  private(set) var acting: Set<EntityRef> = []
  var notice: AskNotice?
  var consentPrompt: AIConsentRequest?

  private let context: MemoirScreenContext
  private let access: InsightAccess
  private let consents: InsightConsents
  /// A question held for the call's consent, asked again under the same id once the owner allows it.
  private var held: (id: UUID, text: String)?
  private var lapse: Task<Void, Never>?
  private var observedReads = 0

  init(context: MemoirScreenContext, access: InsightAccess, consents: InsightConsents) {
    self.context = context
    self.access = access
    self.consents = consents
  }

  var questionLength: Int { question.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count }

  var canSubmit: Bool {
    guard case .ready = setup, !isSubmitting, (1...InsightQuestion.maximumLength).contains(questionLength) else { return false }
    return board.value?.active?.status != .running
  }

  func run() async {
    await refreshSetup()
    defer {
      observedReads += 1
      lapse?.cancel()
      lapse = nil
    }
    let leases = access.leases
    let stream = context.stores.main.observeReads { transaction in try AskMainRead.read(transaction, at: leases.now()) }
    do {
      for try await read in stream {
        observedReads += 1
        try await apply(read)
      }
    } catch is CancellationError {
      return
    } catch {
      board = .failed(PresentedError(error))
    }
  }

  /// The board and its lapse wait are set with no suspension between, so overlapping applies never pair one read's board with another read's wait.
  private func apply(_ read: AskMainRead, isCurrent: () -> Bool = { true }) async throws {
    let results = try await InsightResults.listing(in: context.stores)
    guard isCurrent() else { return }
    board = .loaded(AskBoard(requests: read.listing.requests, results: results, schedule: read.schedule))
    rereadWhenALeaseLapses(read.listing.changesAt)
    await refreshSpend()
  }

  /// A lease lapsing writes nothing, so the store's observation never shows a dead attempt turning queued; the listing is read again a second after the
  /// earliest live lease's expiry, as this device's clock measures it.
  private func rereadWhenALeaseLapses(_ changesAt: Date?) {
    lapse?.cancel()
    lapse = nil
    guard let changesAt else { return }
    let clock = context.clock
    let deadline = max(changesAt, clock.now()).addingTimeInterval(1)
    lapse = Task { [weak self] in
      guard (try? await clock.waitUntil(deadline)) != nil, !Task.isCancelled else { return }
      await self?.reread()
    }
  }

  /// The wait that fired is let go first, so arming the next one cannot cancel this read's own spend refresh. A re-read that `run` ended under, or that the
  /// observation overtook while it was reading, is dropped rather than shown over the newer board, which arms its own lapse wait.
  private func reread() async {
    lapse = nil
    let leases = access.leases
    let observedBefore = observedReads
    do {
      let read = try await context.stores.main.read { transaction in try AskMainRead.read(transaction, at: leases.now()) }
      try await apply(read) { self.observedReads == observedBefore }
    } catch {
      guard observedReads == observedBefore else { return }
      board = .failed(PresentedError(error))
    }
  }

  /// Reads the provider's readiness and the consents again, as after the AI settings or the consent sheet closed.
  func refreshSetup() async {
    guard await access.isProviderReady() else {
      setup = .noProvider
      return
    }
    do {
      let granted = try await consents.granted()
      setup = .ready(granted: Set(AskConsentKind.allCases.filter { granted.contains($0.requirement.dataClass) }))
    } catch {
      notice = .failure(PresentedError(error))
    }
    await refreshSpend()
  }

  func submit() async {
    guard canSubmit else { return }
    let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
    await ask(text, id: UUID.v7())
  }

  /// The consent sheet granted what was asked: a held question is asked again under its own id.
  func consentAllowed() async {
    await refreshSetup()
    guard let held else { return }
    await ask(held.text, id: held.id)
  }

  func requestConsent(_ kind: AskConsentKind) async {
    do {
      consentPrompt = try await access.router().missingConsent(kind.requirement)
    } catch {
      notice = .failure(AIErrors.presented(error, app: .memoir))
    }
  }

  func withdraw(_ kind: AskConsentKind) async {
    do {
      try await consents.withdraw(kind.requirement.dataClass)
    } catch {
      notice = .failure(PresentedError(error))
    }
    await refreshSetup()
  }

  func cancel(_ request: InsightRequest) async {
    await act(on: request) { engine in
      _ = try await engine.cancel(job: request.job)
      return nil
    }
    access.settler?.settle()
  }

  func retry(_ request: InsightRequest) async {
    await act(on: request) { engine in try await engine.retry(job: request.job) }
  }

  /// False when the schedule could not be saved; the failure is the notice.
  @discardableResult
  func setSchedule(question: String, minuteOfDay: Int) async -> Bool {
    let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
    return await writeSchedule { local in InsightScheduleRecord(question: text, minuteOfDay: minuteOfDay, setAt: local) }
  }

  func clearSchedule() async {
    guard let current = board.value?.schedule else { return }
    await writeSchedule { local in InsightScheduleRecord(question: current.question, active: false, minuteOfDay: current.minuteOfDay, setAt: local) }
  }

  private func ask(_ text: String, id: UUID) async {
    isSubmitting = true
    defer { isSubmitting = false }
    do {
      let due = try await access.engine.ask(text, id: id)
      held = nil
      switch due {
      case .waitingForConsent(let request):
        held = (id, text)
        consentPrompt = request
      case .waitingForSpend(let decision):
        notice = .waitingForSpend(decision)
      case .started(let handle):
        question = ""
        notice = .queued
        watch(handle)
      case .succeeded:
        question = ""
        notice = .queued
      case .running:
        question = ""
        notice = .alreadyRunning
      case .cancelled:
        notice = .cancelled
      case .failed(_, let code):
        notice = .failure(AskCopy.failure(code: code))
      case .notScheduled:
        return
      }
    } catch {
      notice = .failure(AskCopy.presented(error))
    }
  }

  private func act(on request: InsightRequest, _ body: (InsightEngine) async throws -> InsightDue?) async {
    guard !acting.contains(request.job) else { return }
    acting.insert(request.job)
    defer { acting.remove(request.job) }
    do {
      switch try await body(access.engine) {
      case .waitingForConsent(let prompt)?: consentPrompt = prompt
      case .waitingForSpend(let decision)?: notice = .waitingForSpend(decision)
      case .failed(_, let code)?: notice = .failure(AskCopy.failure(code: code))
      case .started(let handle)?: watch(handle)
      case .running?: notice = .alreadyRunning
      case .succeeded?, .cancelled?, .notScheduled?, nil: return
      }
    } catch {
      notice = .failure(AskCopy.presented(error))
    }
  }

  /// The attempt runs in the engine whatever this screen does; once it ends, the calls it left pending are priced.
  private func watch(_ handle: AttemptHandle) {
    let access = access
    Task { await access.settle(after: handle) }
  }

  @discardableResult
  private func writeSchedule(_ make: @escaping @Sendable (ZonedFields) -> InsightScheduleRecord) async -> Bool {
    let store = context.stores.store(of: .general)
    do {
      let local = try context.clock.localNow(in: try await AccountZone.load(from: store))
      try await store.write { transaction in try InsightSchedules.set(make(local), in: &transaction) }
      return true
    } catch {
      notice = .failure(AskCopy.presented(error))
      return false
    }
  }

  private func refreshSpend() async {
    let router = await access.router()
    let now = access.leases.now().date
    guard let summary = try? await context.stores.main.read({ transaction in try Spend.summary(in: transaction, now: now, calendar: .current) }) else {
      spend = nil
      return
    }
    let limits = router.configuration.spendLimits
    spend = AskSpend(summary: summary, limits: limits, decision: Spend.decision(for: summary, limits: limits))
  }
}

nonisolated private struct AskMainRead: Sendable, Equatable {
  let listing: InsightRequestListing
  let schedule: InsightScheduleRecord?

  static func read(_ transaction: ReadTransaction, at now: LeaseInstant) throws -> AskMainRead {
    AskMainRead(
      listing: try InsightRequests.listing(in: transaction, at: now),
      schedule: try InsightScheduleRecord.read(key: .insightSchedule, in: transaction).entry?.record)
  }
}
