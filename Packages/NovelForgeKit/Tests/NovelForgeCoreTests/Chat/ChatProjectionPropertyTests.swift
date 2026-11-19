import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForgeCore

private struct OracleItem {
  let ref: EntityRef
  let clock: HLCTimestamp
  let novel: UUID
  let session: UUID
  let isReadable: Bool
  let claims: Bool
  let isUser: Bool
  let covered: Set<UUID>?

  var id: UUID? { UUID(uuidString: ref.key.rawValue) }

  func precedes(_ other: OracleItem) -> Bool { clock == other.clock ? ref < other.ref : clock < other.clock }
}

private struct ExpectedSession: Equatable, CustomStringConvertible {
  let novel: UUID
  let record: ChatSessionRecordState
  let messages: Int
  let unreadable: Int
  let started: Bool
  let latest: EntityKey?
  let updated: HLCTimestamp?
  let summary: EntityKey?
  let unreadableSummaries: Int
  let lock: ChatUnrestrictedLock?
  let transcript: [String]

  var description: String {
    "\(novel) \(record) m=\(messages) u=\(unreadable) s=\(started) latest=\(latest?.rawValue ?? "-") summary=\(summary?.rawValue ?? "-") us=\(unreadableSummaries) "
      + "lock=\(lock.map { "\($0.item.key.rawValue)@\($0.clock)" } ?? "-") \(transcript)"
  }
}

private struct ExpectedProposal: Equatable {
  let novel: UUID
  let readability: ProposalReadability
  let decision: StoredEnum<ProposalDecision>?
  let entries: [ProposalChangeEntryState]
}

private let reached = Mutex(Set<String>())

private func rawMember(_ state: EntityState?, _ name: String) -> JSONValue? {
  guard case .appended(let appended)? = state else { return nil }
  return appended.item[name]
}

private func claimsRaw(_ value: JSONValue?, otherwise: Bool) -> Bool {
  guard let value, !value.isNull else { return otherwise }
  return value.stringValue != ContentMode.standard.rawValue
}

private func isAuthor(_ role: JSONValue?) -> Bool {
  role?.stringValue == ChatRole.user.rawValue
}

private func items(in transaction: ReadTransaction) throws -> [OracleItem] {
  var found = [OracleItem]()
  for (ref, state) in try transaction.states(ofKind: NovelForgeKind.chatMessage.entityKind, scope: .vault) {
    switch ChatMessageRecord.reading(state, of: ref) {
    case .absent: continue
    case .readable(let entry):
      let message = entry.record
      let claims = message.contentMode.map { $0.rawValue != ContentMode.standard.rawValue } ?? (message.role != .known(.user))
      found.append(
        OracleItem(
          ref: ref, clock: entry.clock, novel: message.novel, session: message.session, isReadable: true, claims: claims, isUser: message.role == .known(.user),
          covered: nil))
    case .unreadable:
      guard case .appended(let appended) = state, let novel = rawMember(state, "novel").flatMap(UUID.init(json:)),
        let session = rawMember(state, "session").flatMap(UUID.init(json:))
      else { continue }
      let claims = claimsRaw(rawMember(state, "content_mode"), otherwise: !isAuthor(rawMember(state, "role")))
      found.append(
        OracleItem(ref: ref, clock: appended.clock, novel: novel, session: session, isReadable: false, claims: claims, isUser: false, covered: nil))
    }
  }
  for (ref, state) in try transaction.states(ofKind: NovelForgeKind.chatSummary.entityKind, scope: .vault) {
    switch ChatSummaryRecord.reading(state, of: ref) {
    case .absent: continue
    case .readable(let entry):
      let summary = entry.record
      found.append(
        OracleItem(
          ref: ref, clock: entry.clock, novel: summary.novel, session: summary.session, isReadable: true,
          claims: summary.contentMode.rawValue != ContentMode.standard.rawValue, isUser: false, covered: Set(summary.covered)))
    case .unreadable:
      guard case .appended(let appended) = state, let novel = rawMember(state, "novel").flatMap(UUID.init(json:)),
        let session = rawMember(state, "session").flatMap(UUID.init(json:))
      else { continue }
      found.append(
        OracleItem(
          ref: ref, clock: appended.clock, novel: novel, session: session, isReadable: false, claims: claimsRaw(rawMember(state, "content_mode"), otherwise: true),
          isUser: false, covered: nil))
    }
  }
  return found
}

private func expectedSessions(in transaction: ReadTransaction) throws -> [UUID: ExpectedSession] {
  let all = try items(in: transaction)
  var ids = Set(all.map(\.session))
  for (ref, _) in try transaction.states(ofKind: NovelForgeKind.chatSession.entityKind, scope: .vault) {
    if let id = UUID(uuidString: ref.key.rawValue), NovelForgeKey.chatSession(id) == ref { ids.insert(id) }
  }
  var expected = [UUID: ExpectedSession]()
  var facts = Set<String>()
  for id in ids {
    let ref = NovelForgeKey.chatSession(id)
    let state = try transaction.state(of: ref, scope: .vault)
    var record = ChatSessionRecordState.absent
    var novel: UUID?
    switch ChatSessionRecord.reading(state, of: ref) {
    case .absent: break
    case .readable(let entry): (record, novel) = (entry.isRemoved ? .removed : .live, entry.record.novel)
    case .unreadable:
      record = .unreadable
      if case .record(let stored)? = state { novel = stored[field: "novel"].flatMap { UUID(json: $0.value) } }
    }
    let own = all.filter { $0.session == id }.sorted { $0.precedes($1) }
    guard let novel = novel ?? own.first?.novel else { continue }
    let messages = own.filter { $0.ref.kind == NovelForgeKind.chatMessage.entityKind }
    let summaries = own.filter { $0.ref.kind == NovelForgeKind.chatSummary.entityKind }
    let shown = messages.filter { $0.novel == novel }
    var standing: OracleItem?
    for summary in summaries where summary.isReadable && summary.novel == novel {
      guard let best = standing, let bestCovered = best.covered, let covered = summary.covered else {
        standing = summary
        continue
      }
      if covered.count > bestCovered.count || (covered.count == bestCovered.count && best.precedes(summary)) { standing = summary }
    }
    let covered = standing?.covered ?? []
    var clocks = own.map(\.clock)
    if case .record(let stored)? = state { clocks += stored.fields.values.map(\.clock) }
    let lock = own.first { $0.claims }.map { ChatUnrestrictedLock(item: $0.ref, clock: $0.clock) }
    if lock != nil { facts.insert("locked session") }
    if standing != nil { facts.insert("standing summary") }
    if summaries.count { $0.isReadable && $0.novel == novel } >= 2 { facts.insert("competing summaries") }
    if shown.contains(where: { $0.id.map(covered.contains) ?? false }) { facts.insert("covered message") }
    if shown.contains(where: { !$0.isReadable }) { facts.insert("unreadable message") }
    if messages.count != shown.count { facts.insert("message of another novel") }
    if record == .absent, !own.isEmpty { facts.insert("messages before their session") }
    if summaries.contains(where: { $0.isReadable && $0.novel != novel && ($0.covered?.count ?? 0) > (standing?.covered?.count ?? 0) }) {
      facts.insert("wider summary of another novel")
    }
    expected[id] = ExpectedSession(
      novel: novel, record: record, messages: shown.count, unreadable: shown.count { !$0.isReadable } + messages.count - shown.count,
      started: shown.contains { $0.isReadable && $0.isUser }, latest: shown.last?.ref.key, updated: clocks.max(), summary: standing?.ref.key,
      unreadableSummaries: summaries.count { !$0.isReadable || $0.novel != novel }, lock: lock,
      transcript: shown.map { "\($0.ref.key.rawValue)\($0.id.map(covered.contains) == true ? "+" : "")" })
  }
  reached.withLock { $0.formUnion(facts) }
  return expected
}

private func entryState(_ entry: ProposalChangeEntry, isAction: Bool) -> ProposalChangeEntryState {
  switch entry {
  case .recorded(let change):
    switch (isAction ? change.actionOutcome : change.status).known {
    case .applied: .applied
    case .pending: .pending
    case .failed: .failed
    case .reverted: .reverted
    case nil: .unrecognised
    }
  case .unreadable: .unreadable
  case .awaiting: .awaiting
  case .declined: .declined
  case .notApplied: .notApplied
  }
}

private func expectedProposals(in transaction: ReadTransaction) throws -> [UUID: ExpectedProposal] {
  var expected = [UUID: ExpectedProposal]()
  var facts = Set<String>()
  for (ref, state) in try transaction.states(ofKind: NovelForgeKind.proposal.entityKind, scope: .vault) {
    guard let id = UUID(uuidString: ref.key.rawValue) else { continue }
    switch try ProposalRecord.read(ref, in: transaction) {
    case .absent:
      continue
    case .readable(let entry):
      let proposal = entry.record
      let entries = try ProposalChangeRecord.changes(of: proposal, in: transaction).enumerated().map { index, change in
        entryState(change, isAction: proposal.card.changeSet[index].op.map(isActionOp) ?? false)
      }
      for state in entries { facts.insert("entry \(state.rawValue)") }
      expected[id] = ExpectedProposal(novel: proposal.novel, readability: .readable, decision: proposal.decision, entries: entries)
    case .unreadable:
      guard case .record(let stored) = state, let card = stored[field: "card"]?.value else { continue }
      let decision = stored[field: "decision"].flatMap { StoredEnum<ProposalDecision>(json: $0.value) }
      if let readable = ProposalCard(json: card) {
        facts.insert("application unreadable")
        var entries = [ProposalChangeEntryState]()
        for index in readable.changeSet.indices {
          let isAction = readable.changeSet[index].op.map(isActionOp) ?? false
          switch try ProposalChangeRecord.read(try ProposalChangeRecord.ref(novel: readable.novel, proposal: id, index: index), in: transaction) {
          case .readable(let change): entries.append(entryState(.recorded(change.record), isAction: isAction))
          case .unreadable(let reason): entries.append(entryState(.unreadable(reason), isAction: isAction))
          case .absent: entries.append(decision == .known(.applied) ? .awaiting : .notApplied)
          }
        }
        for state in entries { facts.insert("entry \(state.rawValue)") }
        expected[id] = ExpectedProposal(novel: readable.novel, readability: .applicationUnreadable, decision: decision, entries: entries)
      } else if let novel = card["novel"].flatMap(UUID.init(json:)) {
        facts.insert("card unreadable")
        expected[id] = ExpectedProposal(novel: novel, readability: .cardUnreadable, decision: decision, entries: [])
      }
    }
  }
  for (ref, state) in try transaction.states(ofKind: NovelForgeKind.proposalChange.entityKind, scope: .vault) {
    guard let key = try? NovelForgeKey(reading: state, of: ref), case .proposalChange(let proposal, _) = key.components else { continue }
    if let owner = expected[proposal]?.novel, owner != key.novel { facts.insert("change under another novel") }
  }
  reached.withLock { $0.formUnion(facts) }
  return expected
}

private func oracle(_ reconciler: NovelForgeReconciler, _ store: VaultStore, _ universe: ProjectionUniverse) async throws {
  let (sessions, proposals) = try await store.read { transaction in (try expectedSessions(in: transaction), try expectedProposals(in: transaction)) }
  let states = try await Projection.fetch(ChatSessionState.all(), in: store)
  var actualSessions = [UUID: ExpectedSession]()
  for state in states {
    let transcript = try await ChatWorld.transcript(state.session, in: store).map { "\($0.message.rawValue)\($0.isCovered ? "+" : "")" }
    actualSessions[state.session] = ExpectedSession(
      novel: state.novel, record: state.record, messages: state.messages, unreadable: state.unreadableMessages, started: state.isStarted, latest: state.latest,
      updated: state.updated, summary: state.summary, unreadableSummaries: state.unreadableSummaries, lock: state.lock, transcript: transcript)
  }
  guard actualSessions == sessions else { throw ProjectionPropertyFailure.oracle("chat sessions \(actualSessions) differ from \(sessions)") }

  var actualProposals = [UUID: ExpectedProposal]()
  for state in try await Projection.fetch(ProposalState.all(), in: store) {
    let entries = try await ChatWorld.entries(state.proposal, in: store)
    guard state.rank == ProposalSnapshot.rank(of: state.decision) else { throw ProjectionPropertyFailure.oracle("rank of \(state.proposal)") }
    actualProposals[state.proposal] = ExpectedProposal(novel: state.novel, readability: state.readability, decision: state.decision, entries: entries)
  }
  guard actualProposals == proposals else { throw ProjectionPropertyFailure.oracle("proposals \(actualProposals) differ from \(proposals)") }
}

@Suite("Chat projection property", TestTimeLimit.property)
struct ChatProjectionPropertyTests {
  @Test(arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldMatchARebuildAtEveryStepAndAgreeWithTheOracleOnEveryReplica(order: CausalReplicaOrder) async throws {
    let property = ProjectionProperty(
      derivations: ChatDerivations.all, operations: ProjectionOperations.novels + ProjectionOperations.chat, iterations: 10, steps: 48, gated: true,
      settled: oracle)
    try await property.check(order: order, seed: order == .causal ? 0xF23A0 : 0xF23A1)
    let gate: Set<String> = [
      "locked session", "standing summary", "competing summaries", "covered message", "unreadable message", "message of another novel", "card unreadable",
      "application unreadable", "entry applied", "entry pending", "entry reverted", "entry declined", "entry not_applied", "entry failed", "entry awaiting",
      "entry unreadable", "entry unrecognised", "messages before their session", "wider summary of another novel", "change under another novel",
    ]
    #expect(gate.subtracting(reached.withLock { $0 }).isEmpty, "reached: \(reached.withLock { $0 }.sorted())")
  }
}
