import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport

@testable import NovelForgeCore

/// The keys a run draws from: few enough that devices collide on them, two novels so per-novel derivations stay apart.
struct DomainUniverse: Sendable {
  let primary: UUID
  let second: UUID
  let chapters = 1...4
  let entities = ["mara", "oren", "ilsa"]
  let secrets = ["heir", "tide", "crown"]
  let milestones = ["rise", "fall"]
  let volumes = ["one", "two"]
  let promises: [PromiseRef] = [.thread("oath"), .mystery("door")]
  let pages: [(section: BiblePageSection, slug: String)] = [(.world, "harbour"), (.plot, "outline")]
  let topics = ["plot.tone", "cast.mara", "plot.tone", "start.brief"]
  let texts = ["Ember", "Tide", "Salt", "  "]

  init(_ generator: inout SeededGenerator) {
    primary = generator.uuid()
    second = generator.uuid()
  }

  var novels: [UUID] { [primary, second] }

  func novel(_ generator: inout SeededGenerator) -> UUID { generator.chance(0.85) ? primary : second }
  func chapter(_ generator: inout SeededGenerator) -> Int { generator.int(in: chapters) }
  func entity(_ generator: inout SeededGenerator) -> String { generator.pick(from: entities) }
  func secret(_ generator: inout SeededGenerator) -> String { generator.pick(from: secrets) }
  func milestone(_ generator: inout SeededGenerator) -> String { generator.pick(from: milestones) }
  func volume(_ generator: inout SeededGenerator) -> String { generator.pick(from: volumes) }
  func promise(_ generator: inout SeededGenerator) -> PromiseRef { generator.pick(from: promises) }
  func page(_ generator: inout SeededGenerator) -> (section: BiblePageSection, slug: String) { generator.pick(from: pages) }
  func text(_ generator: inout SeededGenerator) -> String { generator.pick(from: texts) }
  func prose(_ generator: inout SeededGenerator) -> String { "\(generator.pick(from: texts.dropLast())) \(generator.int(in: 0...9))." }

  func learns(_ generator: inout SeededGenerator) -> [KnowledgeReveal] {
    (0..<generator.int(in: 0...2)).map { _ in KnowledgeReveal(entityKey: entity(&generator), factKey: secret(&generator)) }
  }

  func claims(_ generator: inout SeededGenerator) -> [String]? {
    guard generator.chance(0.6) else { return nil }
    return generator.chance(0.25) ? [] : [milestone(&generator)]
  }

  /// One device lays the novel down: a cast, two secrets shown from chapters 1 and 2, the milestone `rise`, the volume `one` and a Notebook direction.
  func setUp(on replicas: CausalReplicas) async throws {
    let novel = primary
    _ = try await replicas.write(0) { transaction in
      try Library.create(NewNovel(title: "Ember", notes: "A tide that turns."), id: novel, in: &transaction)
      for entity in entities { try Entities.create(novel: novel, entity: entity, type: .character, name: entity.capitalized, in: &transaction) }
      try Secrets.upsert(novel: novel, secret: "heir", text: "Mara is the heir.", SecretChanges(revealChapter: .set(1)), in: &transaction)
      try Secrets.upsert(novel: novel, secret: "tide", text: "The tide is forged.", SecretChanges(revealChapter: .set(2)), in: &transaction)
      try Milestones.create(novel: novel, milestone: "rise", label: "The rise", in: &transaction)
      try Volumes.create(novel: novel, volume: "one", ordinal: 1, in: &transaction)
      _ = try Notebook.recordByAuthor(AuthorNotebookEntry(kind: .direction, topic: "plot.tone", statement: "Keep it bleak."), novel: novel, in: &transaction)
    }
    try await replicas.settle()
  }

  /// What a property case starts from beyond `setUp`, so its first partition already races over a story in progress: the milestone `fall`, the volume
  /// `two`, and chapter 1 approved, teaching Mara the heir.
  func prologue(on replicas: CausalReplicas) async throws {
    let novel = primary
    await replicas.advanceClock(of: 0, by: .seconds(700))
    let now = await replicas.store(0).wallClock()
    var plan = PlanEdit(body: "The plan.")
    plan.knowledge = .set(PlanKnowledge(pov: ["mara"], learns: [KnowledgeReveal(entityKey: "mara", factKey: "heir")]))
    let edit = plan
    let revision = try await replicas.write(0) { transaction in
      try Milestones.create(novel: novel, milestone: "fall", label: "The fall", in: &transaction)
      try Volumes.create(novel: novel, volume: "two", ordinal: 2, in: &transaction)
      try ChapterPlans.write(novel: novel, chapter: 1, edit, in: &transaction)
      return try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "Chapter 1.", summary: "It turns."), base: nil, at: now, in: &transaction).base
    }
    try await replicas.store(0).approveChapter(novel: novel, chapter: 1, revision: revision, id: UUID(uuid: (0xD2, 0x5F, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1)))
    try await replicas.collect(0)
    try await replicas.settle()
  }
}
