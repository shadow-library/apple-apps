import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Synchronization

@testable import NovelForgeCore

/// Where a held turn stands: it has asked the model, it has ended, and it may go on.
final class TurnGate: Sendable {
  private let state = Mutex((reached: false, ended: false, released: false))

  func reach() {
    state.withLock { $0.reached = true }
  }

  func release() {
    state.withLock { $0.released = true }
  }

  func passed() async {
    while !state.withLock({ $0.released }), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
  }

  /// Waits until `turn` asks the model, true, or ends without asking, false.
  func reached(by turn: ChatTurnHandle) async -> Bool {
    Task { [self] in
      _ = await turn.outcome()
      state.withLock { $0.ended = true }
    }
    while !Task.isCancelled {
      let (reached, ended) = state.withLock { ($0.reached, $0.ended) }
      if reached || ended { return reached }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }
}

/// One device's model: a fold answers from the request, a chat turn takes the next reply queued for this device; after `holdNextTurn` the next turn waits
/// at its gate before streaming.
final class DeviceModel: ModelProvider {
  let device: Int
  private let replies = Mutex<[[ScriptedModelProvider.Step]]>([])
  private let gate = Mutex<TurnGate?>(nil)
  private let folds = Mutex(0)

  init(device: Int) {
    self.device = device
  }

  func queue(_ steps: [ScriptedModelProvider.Step]) {
    replies.withLock { $0.append(steps) }
  }

  func holdNextTurn() -> TurnGate {
    let next = TurnGate()
    gate.withLock { $0 = next }
    return next
  }

  func clear() {
    replies.withLock { $0.removeAll() }
    gate.withLock { $0 = nil }
  }

  func stream(_ request: ModelRequest) -> ModelStream {
    if request.system.contains(where: { $0.text.contains(chatCompactSystem) }) {
      let fold = folds.withLock { count in
        count += 1
        return count
      }
      return ScriptedModelProvider(calls: [CompactionWorld.reply("Device \(device) fold \(fold).")]).stream(request)
    }
    let steps = replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    let scripted = ScriptedModelProvider(calls: steps.map { [$0] } ?? [])
    let held = gate.withLock { gate in
      defer { gate = nil }
      return gate
    }
    return ModelStream { continuation throws(ModelError) in
      held?.reach()
      await held?.passed()
      for try await event in scripted.stream(request) { try continuation.yield(event) }
    }
  }

  func validate(_ credential: ProviderCredential) async throws(ModelError) -> CredentialStatus {
    throw .invalidRequest("DeviceModel validates no credential")
  }

  func models() async throws(ModelError) -> [RemoteModel] {
    []
  }
}

private struct DeviceCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    ProviderCredential(origin: provider == .anthropic ? CompactionWorld.anthropic : CompactionWorld.openRouter, secret: "sk-test")
  }
}

/// A replica as the app runs it: its store, its own model and router, and its turn engine.
struct ChatDevice: Sendable {
  let index: Int
  let store: VaultStore
  let model: DeviceModel
  let router: TaskRouter
  let engine: ChatTurnEngine

  func holds(_ proposal: UUID) async throws -> Bool {
    try await store.read { transaction in try ProposalRecord.read(id: proposal, in: transaction).entry != nil }
  }
}

enum ChatReplicaFailure: Error, CustomStringConvertible {
  case unexpected(String, any Error)
  case turnFailed(String, TurnFailure)
  case invariant(String)

  var description: String {
    switch self {
    case .unexpected(let operation, let error): "\(operation) threw \(error)"
    case .turnFailed(let operation, let failure): "\(operation) failed: \(failure.code) \(failure.message)"
    case .invariant(let text): text
    }
  }
}

private func require(_ condition: Bool, _ text: @autoclosure () -> String) throws(ChatReplicaFailure) {
  if !condition { throw .invariant(text()) }
}

enum ChatReplicaWorld {
  static let novel = SchemaFixture.novel
  static let session = ChatWorld.session
  static let now = Date(timeIntervalSince1970: 1_700_000_000)
  static var applyContext: ProposalApplyContext { ProposalApplyContext(novel: novel, now: now) }
  static var revertContext: ProposalRevertContext { ProposalRevertContext(novel: novel, now: now) }

  /// The novel (`mara`, milestone `rise`) and an active chat in `auto` mode on every replica, each with its consent granted, its model, router and engine.
  static func devices(count: Int, order: CausalReplicaOrder = .causal, seed: UInt64) async throws -> (NovelForgeReconciler, CausalReplicas, [ChatDevice]) {
    let reconciler = try Projection.reconciler()
    let replicas = try await CausalReplicas(
      CausalReplicaSetup(count: count, registry: Projection.registry, migrations: reconciler.migrations, order: order, reconciler: { _ in reconciler }, seed: seed))
    let (novel, session) = (novel, session)
    _ = try await replicas.write(0) { transaction in
      _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
      try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
      try PlanWorldWrites.milestone(novel: novel, "rise", in: &transaction)
      _ = try ChatSessionRecord(id: session, novel: novel).create(in: &transaction)
    }
    var devices = [ChatDevice]()
    for index in 0..<count {
      let store = await replicas.store(index)
      let model = DeviceModel(device: index)
      let router = try await router(model, store: store)
      let timing = ChatTurnEngine.Timing(flushInterval: .seconds(3_600), monotonic: ChatTurnEngine.Timing.standard.monotonic, now: { Date() })
      let engine = ChatTurnEngine(
        store: store, router: { router }, consent: CompactionWorld.consent, upkeep: RecordedUpkeep().seam, timing: timing,
        unrestrictedAvailable: true)
      _ = try await replicas.write(index) { _ in }
      devices.append(ChatDevice(index: index, store: store, model: model, router: router, engine: engine))
    }
    try await replicas.settle()
    return (reconciler, replicas, devices)
  }

  private static func router(_ provider: DeviceModel, store: VaultStore) async throws -> TaskRouter {
    guard let standard = ProviderBinding(origin: CompactionWorld.anthropic, provider: provider),
      let unrestricted = ProviderBinding(origin: CompactionWorld.openRouter, provider: provider)
    else { throw ChatReplicaFailure.invariant("no provider binding") }
    let consent = CompactionWorld.consent
    try await store.write { transaction in
      for host in [standard.host, unrestricted.host] {
        try AIConsent.decide(.granted, provider: host, dataClass: consent.dataClass, summary: consent.disclosure, atMillis: 1, in: &transaction)
      }
    }
    let configuration = TaskRouterConfiguration(provider: .anthropic, assignments: OpenRouterAssignments(unrestricted: CompactionWorld.unrestrictedModel))
    return TaskRouter(
      configuration: configuration, anthropic: standard, openRouter: unrestricted, credentials: DeviceCredentials(), store: store,
      requestGuard: { ModelRequestGuard.hardLine(for: $0) })
  }
}

/// A turn the test scripts for one device: the author's message, the model's reply with its change set, and the entity keys the change set creates or
/// removes. A quoted character goes straight in, a place is an idea, an edit of `mara` is shared by every device, and a removal is always a card; a
/// discussing turn cards both creations and nothing else, so devices can apply it apart.
struct ChatTurnScript: Sendable {
  let message: String
  let reply: [ScriptedModelProvider.Step]
  let creates: [String]
  let removes: [String]
  let choices: ChatTurnChoices

  private static let firstNames = ["Ash", "Bryn", "Cole"]
  private static let lamps = ["brass", "copper", "silver", "tin", "glass"]

  static func key(device: Int, serial: Int) -> (key: String, name: String) {
    var letters = ""
    var rest = serial
    repeat {
      letters.append(Character(Unicode.Scalar(UInt8(97 + rest % 26))))
      rest /= 26
    } while rest > 0
    let name = firstNames[device % firstNames.count] + letters
    return (name.lowercased(), name)
  }

  static func quoted(_ key: String, _ name: String) -> String {
    #"{"op":"entity.upsert","entityKey":"\#(key)","type":"character","name":"\#(name)","status":"smuggler","quote":"\#(name) is a smuggler who works the Saltgate docks"}"#
  }

  static func idea(_ key: String, _ name: String) -> String {
    #"{"op":"entity.upsert","entityKey":"\#(key)","type":"location","name":"\#(name) Hall"}"#
  }

  static func maraEdit(_ lamp: String) -> String {
    #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","motivation":"She wants the \#(lamp) lamp."}"#
  }

  static func removal(_ key: String) -> String {
    #"{"op":"entity.remove","entityKey":"\#(key)"}"#
  }

  static func make(device: Int, serial: Int, removable: [String], unrestricted: Double, _ generator: inout SeededGenerator) -> ChatTurnScript {
    let (key, name) = key(device: device, serial: serial)
    let discussing = generator.chance(0.25)
    var (ops, creates, removes) = ([String](), [String](), [String]())
    if discussing || generator.chance(0.8) {
      ops.append(quoted(key, name))
      creates.append(key)
    }
    if discussing || generator.chance(0.4) {
      ops.append(idea("\(key)-hall", name))
      creates.append("\(key)-hall")
    }
    if !discussing, generator.chance(0.3) { ops.append(maraEdit(generator.pick(from: lamps))) }
    if !discussing, !removable.isEmpty, generator.chance(0.35) {
      let target = generator.pick(from: removable)
      ops.append(removal(target))
      removes.append(target)
    }
    let content = generator.chance(0.15) ? String(repeating: "The docks are loud at night. ", count: 400) : ""
    let mode: ContentMode? = generator.chance(unrestricted) ? .unrestricted : nil
    let choices = ChatTurnChoices(contentMode: mode, justDiscussing: discussing)
    let text = EngineWorld.text("Noted \(name).")
    let reply = ops.isEmpty ? EngineWorld.reply(("reply", text)) : EngineWorld.reply(("reply", text), ("changeSet", "[\(ops.joined(separator: ","))]"))
    return ChatTurnScript(
      message: "\(name) is a smuggler who works the Saltgate docks. \(content)", reply: reply, creates: creates, removes: removes, choices: choices)
  }
}

/// What the devices did, as the test saw it: the oracle the converged replicas are checked against.
struct ChatReplicaLedger: Sendable {
  struct Waiting: Sendable, Equatable {
    let device: Int
    let turn: UUID
    let message: UUID
  }

  var written: [[UUID]]
  var replies: [UUID: UUID] = [:]
  var waiting: [Waiting] = []
  var cards: [UUID] = []
  var applied: [UUID] = []
  var created: [String] = []
  var removed: Set<String> = []
  var serials: [Int]
  var unrestricted = false
  /// Each card's applies, by device, as the indexes each selected.
  var selections: [UUID: [Int: Set<Int>]] = [:]
  var retried: Set<UUID> = []
  /// The card or message the step's first device worked on, which a second device in the same step works on too, and the indexes its apply chose.
  var target: UUID?
  var targetSelection: Set<Int>?

  init(devices: Int) {
    written = Array(repeating: [], count: devices)
    serials = Array(repeating: 0, count: devices)
  }

  mutating func cardTarget(_ proposals: [UUID], _ generator: inout SeededGenerator) -> UUID? {
    if let target, proposals.contains(target) { return target }
    guard !proposals.isEmpty else { return nil }
    target = generator.pick(from: proposals)
    return target
  }

  mutating func waitingTarget(_ candidates: [Waiting], _ generator: inout SeededGenerator) -> Waiting? {
    if let target, let same = candidates.first(where: { $0.message == target }) { return same }
    guard !candidates.isEmpty else { return nil }
    let picked = generator.pick(from: candidates)
    target = picked.message
    return picked
  }

  mutating func nextSerial(_ device: Int) -> Int {
    defer { serials[device] += 1 }
    return serials[device]
  }

  mutating func wrote(_ message: UUID, on device: Int, unrestricted mode: Bool) {
    written[device].append(message)
    if mode { unrestricted = true }
  }

  mutating func staged(_ script: ChatTurnScript) {
    created += script.creates
    removed.formUnion(script.removes)
  }

  mutating func record(reply: UUID, answering message: UUID, on device: Int, in store: VaultStore) async throws {
    written[device].append(reply)
    replies[reply] = message
    let links = try await store.read { transaction in try ChatMessageRecord.read(id: reply, in: transaction).entry?.record }
    if let card = links?.cardProposal { cards.append(card) }
    if let applied = links?.appliedProposal { self.applied.append(applied) }
  }

  mutating func applied(_ proposal: UUID, on device: Int, selecting indexes: Set<Int>) {
    selections[proposal, default: [:]][device] = indexes
    if !applied.contains(proposal) { applied.append(proposal) }
  }
}

/// Every converged replica against the others and against the ledger, after full delivery.
enum ChatConvergence {
  /// A replica's view of one proposal: its decision's rank and its `applied` field as stored, with the clock that orders first writers.
  struct View: Sendable {
    let rank: Int
    let applied: FieldState?
  }

  typealias Decisions = [UUID: View]

  private static func rank(_ decision: StoredEnum<ProposalDecision>) -> Int {
    decision.known.flatMap { ProposalDecision.allCases.firstIndex(of: $0) } ?? -1
  }

  /// Each replica's view of every proposal, taken before the final settle: a monotone decision merges to the highest of them, and `applied` to the
  /// earliest any replica wrote.
  static func decisions(on devices: [ChatDevice]) async throws -> [Decisions] {
    var views = [Decisions]()
    for device in devices {
      views.append(
        try await device.store.read { transaction in
          var views = Decisions()
          for entry in try ProposalRecord.listing(in: transaction).entries {
            let proposal = entry.record
            guard case .record(let stored)? = try transaction.state(of: proposal.ref, scope: .vault) else { continue }
            views[proposal.id] = View(rank: rank(proposal.decision), applied: stored[field: ProposalField.applied.rawValue])
          }
          return views
        })
    }
    return views
  }

  struct Reach: Sendable {
    var repliesToOneMessage = 0
    var raisedByMerge = 0
    var appliedWithTwoSelections = 0
    var summaries = 0
    var competingSummaries = 0
    var locked = false
  }

  @discardableResult
  static func check(
    _ reconciler: NovelForgeReconciler, devices: [ChatDevice], ledger: ChatReplicaLedger, before: [Decisions]
  ) async throws -> Reach {
    var reach = Reach()
    try await expectSameVaultAndTables(reconciler, devices: devices)
    let transcript = try await expectTranscript(devices: devices, ledger: ledger, reach: &reach)
    try await expectActivity(devices: devices, transcript: transcript)
    try await expectWindow(devices: devices, transcript: transcript.map(\.id), reach: &reach)
    try await expectLock(devices: devices, ledger: ledger, reach: &reach)
    try await expectDecisions(devices: devices, before: before, reach: &reach)
    try await expectContent(devices: devices, ledger: ledger)
    reach.appliedWithTwoSelections = ledger.selections.values.count { Set($0.values).count > 1 }
    return reach
  }

  static func expectRebuilt(_ reconciler: NovelForgeReconciler, device: ChatDevice) async throws {
    let comparison = try await Projection.compare(reconciler, in: device.store)
    let differing = comparison.incremental.keys.filter { comparison.incremental[$0] != comparison.rebuilt[$0] }.sorted()
    try require(differing.isEmpty, "replica \(device.index) is not a rebuild: \(differing)")
    let faults = comparison.incremental[reconciler.faultTable] ?? []
    try require(faults.isEmpty, "replica \(device.index) holds faults \(faults)")
  }

  static func expectSameVaultAndTables(_ reconciler: NovelForgeReconciler, devices: [ChatDevice]) async throws {
    let digest = try await devices[0].store.loadState(.vault).digest
    let tables = try await Projection.derived(reconciler, in: devices[0].store)
    for device in devices {
      try require(try await device.store.loadState(.vault).digest == digest, "replica \(device.index) holds another vault state")
      try await expectRebuilt(reconciler, device: device)
      let derived = try await Projection.derived(reconciler, in: device.store)
      let diverged = Set(tables.keys).union(derived.keys).filter { derived[$0] != tables[$0] }.sorted()
      try require(diverged.isEmpty, "replica \(device.index) derives other tables: \(diverged)")
    }
  }

  /// One transcript on every replica: every message any device wrote, once, each device's own in the order it wrote them, every reply after the message it
  /// answers and recording it as the one it answers.
  private static func expectTranscript(devices: [ChatDevice], ledger: ChatReplicaLedger, reach: inout Reach) async throws -> [ChatMessageRecord] {
    let session = ChatReplicaWorld.session
    var first: [ChatMessageRecord]?
    for device in devices {
      let messages = try await device.store.read { transaction in try ChatTranscript.messages(of: session, in: transaction) }
      try require(messages.map(\.position) == messages.indices.map { $0 + 1 }, "replica \(device.index) skips a position")
      let records = messages.compactMap(\.record)
      try require(records.count == messages.count, "replica \(device.index) cannot read a message")
      if let first { try require(records.map(\.id) == first.map(\.id), "replica \(device.index) orders the transcript differently") } else { first = records }
    }
    let records = first ?? []
    let transcript = records.map(\.id)
    let written = ledger.written.flatMap { $0 }
    try require(transcript.count == written.count && Set(transcript) == Set(written), "the transcript is not every message written once")
    for (device, own) in ledger.written.enumerated() {
      try require(transcript.filter(Set(own).contains) == own, "device \(device)'s messages are out of the order it wrote them")
    }
    let position = Dictionary(uniqueKeysWithValues: transcript.enumerated().map { ($0.element, $0.offset) })
    for (reply, message) in ledger.replies {
      guard let at = position[reply], let asked = position[message] else { throw ChatReplicaFailure.invariant("reply \(reply) or its message is missing") }
      try require(asked < at, "reply \(reply) stands before the message it answers")
      try require(records[at].answers == message, "reply \(reply) records that it answers \(String(describing: records[at].answers)), not \(message)")
    }
    let answered = records.filter { $0.role == .known(.assistant) }.compactMap(\.answers)
    reach.repliesToOneMessage += Dictionary(grouping: answered) { $0 }.values.count { $0.count > 1 }
    return records
  }

  /// No turn is left pending, and each device shows the session idle, or waiting on the last author message: answered elsewhere, or its own failed turn.
  private static func expectActivity(devices: [ChatDevice], transcript: [ChatMessageRecord]) async throws {
    let last = transcript.last.flatMap { $0.role == .known(.user) ? $0.id : nil }
    for device in devices {
      try require(try await device.store.pendingLocalTurns().isEmpty, "replica \(device.index) holds a pending turn")
      switch try await device.engine.activity(session: ChatReplicaWorld.session) {
      case .idle: try require(last == nil, "replica \(device.index) shows idle on an unanswered message")
      case .answeringElsewhere(let message): try require(message == last, "replica \(device.index) waits on \(message), not the last message")
      case .ended(let turn): try require(turn.userMessage == last, "replica \(device.index) shows an ended turn that is not the last message's")
      case let activity: throw ChatReplicaFailure.invariant("replica \(device.index) shows \(activity)")
      }
    }
  }

  /// The standing summary is one, the same everywhere and the widest; it and the window between them hold every message once.
  private static func expectWindow(devices: [ChatDevice], transcript: [UUID], reach: inout Reach) async throws {
    let (session, novel) = (ChatReplicaWorld.session, ChatReplicaWorld.novel)
    var standings = [UUID?]()
    for device in devices {
      let (window, summaries) = try await device.store.read { transaction in
        (try ChatWindow.load(session, in: transaction).window, try ChatSummaryRecord.listing(session: session, novel: novel, in: transaction).entries)
      }
      guard case .available(let contents?) = window else { throw ChatReplicaFailure.invariant("replica \(device.index) has no window") }
      let covered = Set(contents.summary?.record.covered ?? [])
      let windowed = contents.messages.compactMap(\.record?.id)
      try require(covered.isDisjoint(with: windowed), "replica \(device.index) shows a covered message in the window")
      try require(Set(transcript).subtracting(covered) == Set(windowed), "replica \(device.index) loses a message between the summary and the window")
      try require(windowed == transcript.filter { !covered.contains($0) }, "replica \(device.index) orders the window unlike the transcript")
      let widest = summaries.map { Set($0.record.covered).count }.max()
      try require(contents.summary.map { Set($0.record.covered).count } == widest, "replica \(device.index) stands on a narrower summary")
      standings.append(contents.summary?.record.id)
      try require(standings.allSatisfy { $0 == standings[0] }, "replica \(device.index) stands on another summary")
      reach.summaries = summaries.count
      let sets = summaries.map { Set($0.record.covered) }
      let competing = sets.contains { left in sets.contains { right in !left.isSubset(of: right) && !right.isSubset(of: left) } }
      reach.competingSummaries = competing ? 1 : 0
    }
  }

  /// The session is locked on every replica exactly when some device sent an unrestricted turn.
  private static func expectLock(devices: [ChatDevice], ledger: ChatReplicaLedger, reach: inout Reach) async throws {
    let (session, novel) = (ChatReplicaWorld.session, ChatReplicaWorld.novel)
    for device in devices {
      let (lock, holds) = try await device.store.read { transaction in
        (try ChatWindow.load(session, in: transaction).lock, try ChatSessions.load(novel, in: transaction).holdsUnrestrictedText)
      }
      guard case .available(let held) = lock, case .available(let holding) = holds else { throw ChatReplicaFailure.invariant("replica \(device.index) cannot tell its lock") }
      try require(
        (held != nil) == ledger.unrestricted && holding == ledger.unrestricted,
        "replica \(device.index) lock \(String(describing: held)) after unrestricted \(ledger.unrestricted)")
    }
    reach.locked = ledger.unrestricted
  }

  private static func expectDecisions(devices: [ChatDevice], before: [Decisions], reach: inout Reach) async throws {
    let after = try await decisions(on: devices)
    for (id, merged) in after[0] {
      let views = before.compactMap { $0[id] }
      try require(merged.rank == views.map(\.rank).max(), "proposal \(id) merged to \(merged.rank), not the highest of \(views.map(\.rank))")
      let first = views.compactMap(\.applied).min { earlier, later in
        guard earlier.clock == later.clock else { return earlier.clock < later.clock }
        return CanonicalJSON.encode(earlier.value).lexicographicallyPrecedes(CanonicalJSON.encode(later.value))
      }
      try require(merged.applied == first, "proposal \(id)'s applied is not the first one written")
      if Set(views.map(\.rank).filter { $0 > 0 }).count > 1 { reach.raisedByMerge += 1 }
    }
  }

  /// An entity only one change creates and no change removes stands exactly as that change's record says: the content it applied while applied, what its
  /// undo restored once reverted, absent when it never applied. Concurrent applies of one change leave the same content, whichever revision stands. Accepted:
  /// of two changes creating one entity, undoing one removes what the other still records applied (ChatReplicaInterleavingTests pins it).
  private static func expectContent(devices: [ChatDevice], ledger: ChatReplicaLedger) async throws {
    let novel = ChatReplicaWorld.novel
    let creations = Dictionary(grouping: ledger.created) { $0 }
    let exclusive = Set(creations.filter { $0.value.count == 1 }.keys).subtracting(ledger.removed)
    for device in devices {
      let failures = try await device.store.read { transaction -> [String] in
        var failures = [String]()
        for entry in try ProposalRecord.listing(in: transaction).entries {
          let proposal = entry.record
          let changes = try ProposalChangeRecord.changes(of: proposal, in: transaction)
          for (index, stored) in proposal.card.changeSet.enumerated() {
            guard let op = stored.op, case .entityUpsert = op.operation, let ref = changeSetRefs([op]).first else { continue }
            guard exclusive.contains(String(ref.dropFirst("entity:".count))) else { continue }
            let current = try ArtifactStateLoader.states(refs: [ref], novel: novel, in: transaction)[JSString(ref)]
            let expected: ArtifactState? =
              switch index < changes.count ? changes[index] : .notApplied {
              case .recorded(let change) where change.status == .known(.applied): change.undo?.postState[ref]
              case .recorded(let change) where change.status == .known(.reverted): change.undoneState?[ref]
              case .unreadable: nil
              default: .missing
              }
            guard let expected else { continue }
            if current?.exists != expected.exists || (expected.exists && !sameText(current?.contentHash, expected.contentHash)) {
              failures.append("\(proposal.id)#\(index) \(ref): \(String(describing: current)) against \(expected)")
            }
          }
        }
        return failures
      }
      try require(failures.isEmpty, "replica \(device.index) content disagrees with its change records: \(failures)")
    }
  }
}

/// The refusals a chat operation may meet on a replica that has not heard everything; a store failure, a routing failure or a turn already running is not one.
/// Accepted: a waiting author message that a fold has covered can no longer be answered or retried (`chat_turn.message_not_answerable`).
enum ChatReplicaRefusal {
  static func code(of error: any Error) -> String? {
    switch error {
    case let error as ChatTurnError:
      switch error {
      case .store, .routing, .conversationUnavailable, .turnRunning: nil
      default: error.code
      }
    case let error as ProposalApplyError:
      switch error {
      case .store, .unstorable: nil
      default: error.code
      }
    case let error as ProposalRevertError:
      switch error {
      case .store: nil
      default: error.code
      }
    case let error as ProposalDecisionError:
      switch error {
      case .store: nil
      default: error.code
      }
    default: nil
    }
  }
}
