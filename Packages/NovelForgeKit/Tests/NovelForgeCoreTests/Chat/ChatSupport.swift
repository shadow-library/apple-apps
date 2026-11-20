import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText

@testable import NovelForgeCore

enum ChatWorld {
  static let novel = SchemaFixture.novel
  static let otherNovel = SchemaFixture.otherNovel
  static let sessions = [
    SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000c1"), SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000c2"),
    SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000c3"),
  ]
  static let proposals = [
    SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000d1"), SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000d2"),
    SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000d3"),
  ]
  static let session = sessions[0]

  static func message(
    _ id: UUID = UUID(), novel: UUID = novel, session: UUID = session, role: ChatRole = .user, content: String = "Tighten chapter two.", mode: ContentMode? = nil,
    answers: UUID? = nil, cardProposal: UUID? = nil, appliedProposal: UUID? = nil
  ) throws -> ChatMessageRecord {
    try ChatMessageRecord(
      id: id, novel: novel, session: session, role: role, content: content, answers: answers, contentMode: mode, appliedProposal: appliedProposal,
      cardProposal: cardProposal)
  }

  static func summary(_ id: UUID = UUID(), novel: UUID = novel, session: UUID = session, covering covered: [UUID], mode: ContentMode = .standard) throws
    -> ChatSummaryRecord
  {
    try ChatSummaryRecord(id: id, novel: novel, session: session, covered: covered, text: "They agreed on the heir.", contentMode: mode)
  }

  static func item(novel: UUID = novel, session: UUID = session, _ members: [String: JSONValue] = [:]) -> [String: JSONValue] {
    ["novel": novel.json, "session": session.json].merging(members) { _, given in given }
  }

  static func reconciler() throws -> NovelForgeReconciler { try Projection.reconciler() }

  static func store() throws -> (NovelForgeReconciler, VaultStore) {
    let reconciler = try reconciler()
    return (reconciler, try Projection.store(reconciler))
  }

  static func append(_ message: ChatMessageRecord, in store: VaultStore) async throws {
    _ = try await Projection.write(store) { transaction in try message.append(in: &transaction) }
  }

  static func append(_ summary: ChatSummaryRecord, in store: VaultStore) async throws {
    _ = try await Projection.write(store) { transaction in try summary.append(in: &transaction) }
  }

  static func appendRaw(_ ref: EntityRef, _ item: [String: JSONValue], in store: VaultStore) async throws {
    _ = try await Projection.write(store) { transaction in try transaction.append(ref, item: item) }
  }

  static func createSession(_ id: UUID = session, novel: UUID = novel, in store: VaultStore) async throws {
    let record = try ChatSessionRecord(id: id, novel: novel)
    _ = try await Projection.write(store) { transaction in try record.create(in: &transaction) }
  }

  static func state(_ session: UUID = session, in store: VaultStore) async throws -> ChatSessionState? {
    try await Projection.fetch(ChatSessionStateDerivation.request(for: NovelForgeKey.chatSession(session)), in: store).first
  }

  static func transcript(_ session: UUID = session, in store: VaultStore) async throws -> [ChatTranscriptRow] {
    try await Projection.fetch(ChatTranscriptDerivation.request(for: NovelForgeKey.chatSession(session)).order(Column("position")), in: store)
  }

  static func row(_ ref: EntityRef, in store: VaultStore) async throws -> ChatMessageRow? {
    try await Projection.fetch(ChatMessageRowDerivation.request(for: ref), in: store).first
  }

  static func proposalState(_ id: UUID, in store: VaultStore) async throws -> ProposalState? {
    try await Projection.fetch(ProposalStateDerivation.request(for: NovelForgeKey.proposal(id)), in: store).first
  }

  static func entries(_ id: UUID, in store: VaultStore) async throws -> [ProposalChangeEntryState] {
    try await Projection.fetch(ProposalChangeEntryDerivation.request(for: NovelForgeKey.proposal(id)).order(Column("op")), in: store).map(\.state)
  }

  static func stage(_ proposal: ProposalRecord, in store: VaultStore) async throws {
    _ = try await Projection.write(store) { transaction in try proposal.create(in: &transaction) }
  }

  /// Index 3 of the fixture card is an action: an apply records it pending and with no undo.
  static func appliedChange(of proposal: ProposalRecord, _ index: Int) throws -> ProposalChangeRecord {
    guard index != 3 else { return try ProposalFixture.change(of: proposal, index, status: .pending) }
    return try ProposalFixture.change(of: proposal, index, undo: try ProposalFixture.undo("p-\(index)"))
  }

  static func applyWrite(_ proposal: ProposalRecord, selected: [Int]) throws -> ProjectionWrite {
    let changes = try selected.map { index in try appliedChange(of: proposal, index) }
    let ref = proposal.ref
    let postState = ProposalFixture.postState("p1")
    return { transaction in _ = try ProposalRecord.recordApply(ref, changes: changes, postState: postState, automatic: false, in: &transaction) }
  }

  static func apply(_ proposal: ProposalRecord, selected: [Int], in store: VaultStore) async throws {
    let write = try applyWrite(proposal, selected: selected)
    try await Projection.write(store, write)
  }

  static func dismiss(_ id: UUID, as dismissal: ProposalDismissal, in store: VaultStore) async throws {
    _ = try await Projection.write(store) { transaction in try ProposalRecord.dismiss(NovelForgeKey.proposal(id), as: dismissal, in: &transaction) }
  }
}

/// Chat and proposal writes for the projection property: typed writes plus the raw shapes a newer or broken writer could leave, purges included.
enum ChatOperations {
  private static func sessionOf(_ generator: inout SeededGenerator, _ universe: ProjectionUniverse) -> (session: UUID, novel: UUID) {
    let index = generator.int(in: 0...(ChatWorld.sessions.count - 1))
    return (ChatWorld.sessions[index], universe.novels[index % universe.novels.count])
  }

  private static func proposalOf(_ generator: inout SeededGenerator, _ universe: ProjectionUniverse) -> (proposal: UUID, novel: UUID) {
    let index = generator.int(in: 0...(ChatWorld.proposals.count - 1))
    return (ChatWorld.proposals[index], universe.novels[index % universe.novels.count])
  }

  private static func messages(of session: UUID, in transaction: borrowing WriteTransaction) throws -> [UUID] {
    try transaction.states(ofKind: NovelForgeKind.chatMessage.entityKind, scope: .vault).compactMap { ref, state in
      guard case .appended(let appended) = state, appended.item["session"] == session.json else { return nil }
      return UUID(uuidString: ref.key.rawValue)
    }.sorted { $0.uuidString < $1.uuidString }
  }

  private static func mode(_ generator: inout SeededGenerator) -> ContentMode? {
    generator.pick(from: [nil, nil, ContentMode.standard, .standard, .unrestricted])
  }

  static let all: [ProjectionOperation] = [
    ProjectionOperation(name: "create chat session", weight: 2) { generator, universe in
      let (session, intended) = sessionOf(&generator, universe)
      let owner = generator.chance(0.15) ? universe.novel(&generator) : intended
      return { transaction in _ = try ChatSessionRecord(id: session, novel: owner).create(in: &transaction) }
    },
    ProjectionOperation(name: "rename chat session", weight: 1) { generator, universe in
      let (session, _) = sessionOf(&generator, universe)
      var edit = ChatSessionEdit()
      try? edit.rename(universe.text(&generator))
      let changes = edit
      return { transaction in _ = try ChatSessionRecord.edit(id: session, changes, in: &transaction) }
    },
    ProjectionOperation(name: "remove or restore chat session", weight: 1) { generator, universe in
      let (session, _) = sessionOf(&generator, universe)
      let removes = generator.chance(0.5)
      return { transaction in
        _ = try removes ? ChatSessionRecord.remove(id: session, in: &transaction) : ChatSessionRecord.restore(id: session, in: &transaction)
      }
    },
    ProjectionOperation(name: "append chat message", weight: 8) { generator, universe in
      let (session, intended) = sessionOf(&generator, universe)
      let owner = generator.chance(0.08) ? universe.novel(&generator) : intended
      let (id, role, mode, text, position) = (generator.uuid(), generator.pick(from: ChatRole.allCases), mode(&generator), universe.text(&generator), generator.int(in: 0...999))
      let proposal = generator.chance(0.3) ? generator.pick(from: ChatWorld.proposals) : nil
      return { transaction in
        let earlier = try messages(of: session, in: transaction)
        let answers = earlier.isEmpty || position % 3 != 0 ? nil : earlier[position % earlier.count]
        let message = try ChatWorld.message(
          id, novel: owner, session: session, role: role, content: text, mode: mode, answers: answers, cardProposal: proposal, appliedProposal: nil)
        _ = try message.append(in: &transaction)
      }
    },
    ProjectionOperation(name: "append unreadable chat message", weight: 1) { generator, universe in
      let (session, novel) = sessionOf(&generator, universe)
      let id = generator.uuid()
      let members: [String: JSONValue] = generator.pick(from: [[:], ["content_mode": "unrestricted"], ["content_mode": "standard", "role": .int(3)], ["contexts": "x"]])
      let item = ChatWorld.item(novel: novel, session: session, members)
      return { transaction in _ = try transaction.append(NovelForgeKey.chatMessage(id), item: item) }
    },
    ProjectionOperation(name: "append chat summary", weight: 3) { generator, universe in
      let (session, intended) = sessionOf(&generator, universe)
      let owner = generator.chance(0.08) ? universe.novel(&generator) : intended
      let (id, share, mode, stranger) = (generator.uuid(), generator.int(in: 1...4), generator.chance(0.2) ? ContentMode.unrestricted : .standard, generator.uuid())
      return { transaction in
        let earlier = try messages(of: session, in: transaction)
        let covered = Array(earlier.prefix(max(1, earlier.count * share / 4))) + (earlier.isEmpty ? [stranger] : [])
        _ = try ChatWorld.summary(id, novel: owner, session: session, covering: covered, mode: mode).append(in: &transaction)
      }
    },
    ProjectionOperation(name: "append a wide summary under another novel", weight: 1) { generator, universe in
      let (session, intended) = sessionOf(&generator, universe)
      let owner = universe.novels.first { $0 != intended } ?? intended
      let (id, stranger) = (generator.uuid(), generator.uuid())
      return { transaction in
        let covered = try messages(of: session, in: transaction) + [stranger]
        _ = try ChatWorld.summary(id, novel: owner, session: session, covering: covered).append(in: &transaction)
      }
    },
    ProjectionOperation(name: "append unreadable chat summary", weight: 1) { generator, universe in
      let (session, novel) = sessionOf(&generator, universe)
      let id = generator.uuid()
      let members: [String: JSONValue] = generator.pick(from: [[:], ["content_mode": "standard"], ["covered": "x", "content_mode": "unrestricted"]])
      let item = ChatWorld.item(novel: novel, session: session, members)
      return { transaction in _ = try transaction.append(NovelForgeKey.chatSummary(id), item: item) }
    },
    ProjectionOperation(name: "purge a chat item", weight: 1) { generator, universe in
      let (session, _) = sessionOf(&generator, universe)
      let (position, purges) = (generator.int(in: 0...999), generator.chance(0.4))
      return { transaction in
        let earlier = try messages(of: session, in: transaction)
        guard purges, !earlier.isEmpty else { return }
        _ = try transaction.purge(NovelForgeKey.chatMessage(earlier[position % earlier.count]))
      }
    },
    ProjectionOperation(name: "stage proposal", weight: 5) { generator, universe in
      let (proposal, novel) = proposalOf(&generator, universe)
      return { transaction in _ = try ProposalRecord(id: proposal, card: try ProposalFixture.card(novel: novel)).create(in: &transaction) }
    },
    ProjectionOperation(name: "stage an unreadable proposal", weight: 2) { generator, universe in
      let (proposal, novel) = (ChatWorld.proposals[2], universe.novels[0])
      let card: JSONValue = generator.chance(0.75) ? ["novel": novel.json] : .string("card")
      return { transaction in _ = try transaction.set(NovelForgeKey.proposal(proposal), ["card": card, "decision": "pending"]) }
    },
    ProjectionOperation(name: "dismiss proposal", weight: 2) { generator, universe in
      let (proposal, _) = proposalOf(&generator, universe)
      let dismissal = generator.pick(from: [ProposalDismissal.superseded, .discarded])
      return { transaction in _ = try ProposalRecord.dismiss(NovelForgeKey.proposal(proposal), as: dismissal, in: &transaction) }
    },
    ProjectionOperation(name: "apply proposal", weight: 5) { generator, universe in
      let (proposal, _) = proposalOf(&generator, universe)
      let selected = [0, 1, 2, 3].filter { _ in generator.chance(0.6) }
      return { transaction in
        guard case .readable(let entry) = try ProposalRecord.read(NovelForgeKey.proposal(proposal), in: transaction), !selected.isEmpty else { return }
        try ChatWorld.applyWrite(entry.record, selected: selected)(&transaction)
      }
    },
    ProjectionOperation(name: "write a malformed applied", weight: 1) { generator, universe in
      let (proposal, _) = proposalOf(&generator, universe)
      guard proposal != ChatWorld.proposals[0] else { return { _ in } }
      return { transaction in _ = try transaction.set(NovelForgeKey.proposal(proposal), ["decision": "applied", "applied": .string("applied")]) }
    },
    ProjectionOperation(name: "undo or redo a change", weight: 3) { generator, _ in
      let (position, undoes) = (generator.int(in: 0...999), generator.chance(0.6))
      return { transaction in
        let refs = try transaction.states(ofKind: NovelForgeKind.proposalChange.entityKind, scope: .vault).map(\.ref).sorted()
        guard !refs.isEmpty else { return }
        let ref = refs[position % refs.count]
        _ =
          try undoes
          ? ProposalChangeRecord.recordUndo(ref, undoneState: ProposalFixture.postState("p0"), in: &transaction)
          : ProposalChangeRecord.recordRedo(ref, in: &transaction)
      }
    },
    ProjectionOperation(name: "settle an action", weight: 5) { generator, universe in
      let ((proposal, novel), fails) = (proposalOf(&generator, universe), generator.chance(0.5))
      return { transaction in
        let ref = try ProposalChangeRecord.ref(novel: novel, proposal: proposal, index: 3)
        _ = try ProposalChangeRecord.settleAction(ref, result: ProposalChangeResult(error: fails ? "skipped" : nil), in: &transaction)
      }
    },
    ProjectionOperation(name: "record a change under another novel", weight: 1) { generator, universe in
      let (proposal, intended) = proposalOf(&generator, universe)
      let owner = universe.novels.first { $0 != intended } ?? intended
      let index = generator.int(in: 0...3)
      return { transaction in
        let change = try ProposalChangeRecord(novel: owner, proposal: proposal, index: index, status: .applied, undo: try ProposalFixture.undo("elsewhere"))
        _ = try change.create(in: &transaction)
      }
    },
    ProjectionOperation(name: "write a raw proposal change", weight: 2) { generator, universe in
      let (proposal, novel) = proposalOf(&generator, universe)
      let index = generator.int(in: 0...5)
      let fields: [String: JSONValue] = generator.pick(from: [["status": "applied", "undo": .array([])], ["status": .int(1)], ["status": "dormant"], ["status": "pending"]])
      return { transaction in
        let key = try NovelForgeKey(novel: novel, .proposalChange(proposal: proposal, index: index))
        _ = try transaction.set(key.ref, fields.merging(["natural_key": key.stored]) { given, _ in given })
      }
    },
  ]
}
