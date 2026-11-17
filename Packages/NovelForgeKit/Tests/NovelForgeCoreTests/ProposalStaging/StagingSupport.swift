import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

// apps/novel-forge-server/tests/refinement/passage-rewrite.spec.ts:24-34
enum StagingText {
  static let body = [
    "The salle smelled of chalk. Again, the light came in bars.", "Corin flexed his right hand until the knuckles stopped aching.", "“Again,” Mara said.",
    "He was afraid of her, and he knew it.",
  ].joined(separator: "\n\n")
  static let wrist = "flexed his right hand until the knuckles stopped aching."
  static let wristRewrite = "worked his right wrist in slow circles until the old break stopped grinding."
  static let fear = "He was afraid of her, and he knew it."
  static let fearRewrite = "His grip had gone damp inside the glove."

  static func rewrite(_ passage: String, _ replacement: String, chapter: Int = 3) -> String {
    #"{"op":"draft.rewrite_passage","chapter":\#(chapter),"passage":\#(quoted(passage)),"replacement":\#(quoted(replacement))}"#
  }

  static func quoted(_ text: String) -> String {
    OrderedJSON.string(text).jsonText
  }
}

enum StagingWorld {
  static let session = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000e1")
  static let otherSession = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000e2")

  /// ChapterBook's novel (the learner `mara`, secrets `heir` and `tide`, milestone `rise`) on a store that reconciles every derivation, the chat ones included.
  static func book() async throws -> ChapterBook {
    let clock = OperationClock()
    let reconciler = try Projection.reconciler()
    let store = try VaultStore.open(.inMemory, registry: Projection.registry, migrations: reconciler.migrations, wallClock: clock.function, reconciler: reconciler)
    let book = ChapterBook(store: store, clock: clock)
    let novel = book.novel
    try await book.run { transaction in
      _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
      try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
      try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction)
      try PlanWorldWrites.secret(novel: novel, "tide", revealChapter: 5, in: &transaction)
      try PlanWorldWrites.milestone(novel: novel, "rise", in: &transaction)
    }
    return book
  }

  /// Chapters 1 and 2 final, so the story cursor stands at 2; chapter 3 holds `StagingText.body` as a draft (passage-rewrite.spec.ts:57-69).
  static func workspace() async throws -> ChapterBook {
    let book = try await book()
    try await book.finalized(through: 2)
    try await book.draft(3, StagingText.body)
    return book
  }

  static func changeSet(_ ops: String...) throws -> ValidatedChangeSet {
    try ValidatedChangeSet(try OrderedJSON(parsing: "[\(ops.joined(separator: ","))]"), options: ChangeSetValidationOptions(entityMaterialization: false))
  }

  static func input(_ changeSet: ValidatedChangeSet, novel: UUID, session: UUID? = session, kind: ProposalKind = .hub, warnings: [String]? = []) -> ProposalStagingInput {
    ProposalStagingInput(novel: novel, session: session, kind: kind, changeSet: changeSet, warnings: warnings)
  }
}

extension ChapterBook {
  @discardableResult
  func stage(_ input: ProposalStagingInput) async throws -> StagedProposal {
    try await run { try ProposalStager.stage(input, in: &$0) }
  }

  @discardableResult
  func stage(_ ops: String..., session: UUID? = StagingWorld.session, kind: ProposalKind = .hub, warnings: [String]? = []) async throws -> StagedProposal {
    let changeSet = try ValidatedChangeSet(
      try OrderedJSON(parsing: "[\(ops.joined(separator: ","))]"), options: ChangeSetValidationOptions(entityMaterialization: false))
    return try await stage(StagingWorld.input(changeSet, novel: novel, session: session, kind: kind, warnings: warnings))
  }

  func refusal(_ input: ProposalStagingInput) async -> ProposalStagingError? {
    do {
      _ = try await store.write { try ProposalStager.stage(input, in: &$0) }
      return nil
    } catch {
      guard case .aborted(let cause) = error else { return nil }
      return cause as? ProposalStagingError
    }
  }

  func proposal(_ id: UUID) async throws -> ProposalRecord {
    try await store.read { transaction in try #require(try ProposalRecord.read(id: id, in: transaction).entry?.record) }
  }

  func decision(_ id: UUID) async throws -> StoredEnum<ProposalDecision> {
    try await proposal(id).decision
  }

  func proposalCount() async throws -> Int {
    try await store.read { try ProposalRecord.listing(in: $0).entries.count }
  }

  func setDecision(_ id: UUID, _ raw: String) async throws {
    try await run { transaction in _ = try transaction.set(ProposalRecord.ref(id: id), [ProposalField.decision.rawValue: .string(raw)]) }
  }

  func states(_ refs: [String]) async throws -> [JSString: ArtifactState] {
    let novel = novel
    return try await store.read { try ArtifactStateLoader.states(refs: refs, novel: novel, in: $0) }
  }
}
