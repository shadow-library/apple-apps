import Foundation
import GRDB
import ShadowStore
import Testing

@testable import NovelForgeCore

private typealias Load = @Sendable (ReadTransaction) throws -> Void

private final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var statements: [String] = []

  func add(_ statement: String) { lock.withLock { statements.append(statement) } }

  var all: [String] { lock.withLock { statements } }
}

private enum Scaled {
  static func store(records: Int, revisions: Int) async throws -> VaultStore {
    let store = try ReadWorld.store()
    try await ReadWorld.write(store) { transaction in
      _ = try NovelRecord(id: readNovel, name: "Ember").create(in: &transaction)
      try ChapterWrites.entity(novel: readNovel, "mara", in: &transaction)
      try PlanWorldWrites.secret(novel: readNovel, "heir", revealChapter: 1, in: &transaction)
      for index in 1...records {
        try PlanWorldWrites.putPlan(novel: readNovel, chapter: index, planContent(contract(learns: index == 1 ? [Learn("mara", "heir")] : [])), in: &transaction)
        try ChapterWrites.draft(novel: readNovel, chapter: index, in: &transaction)
        try PlanWorldWrites.volume(novel: readNovel, "v\(index)", ordinal: index, in: &transaction)
        try PlanWorldWrites.milestone(novel: readNovel, "m\(index)", in: &transaction)
        try PlanWorldWrites.secret(novel: readNovel, "s\(index)", in: &transaction)
        try Entities.create(novel: readNovel, entity: "e\(index)", type: .character, name: "E\(index)", in: &transaction)
        _ = try Notebook.record(NewNotebookEntry(kind: .decision, topic: "topic\(index)", statement: "s", decidedBy: .author), novel: readNovel, in: &transaction)
      }
      for index in 1...(records / 2) { try ChapterWrites.finalize(novel: readNovel, chapter: index, in: &transaction) }
    }
    for pass in 0..<revisions {
      try await ReadWorld.write(store) { transaction in
        for index in 1...records {
          _ = try Pages.save(novel: readNovel, section: .world, slug: "p\(index)", body: "Body \(pass) of \(index).", in: &transaction)
          try ChapterWrites.draft(novel: readNovel, chapter: index, body: "Draft \(pass).", source: .handEdited, in: &transaction)
        }
      }
    }
    return store
  }

  static func statements(in store: VaultStore, _ load: @escaping Load) async throws -> [String] {
    try await store.read { transaction in
      let recorder = Recorder()
      transaction.database.trace(options: .statement) { event in recorder.add(event.expandedDescription) }
      try load(transaction)
      transaction.database.trace(options: [], nil)
      return recorder.all
    }
  }

  static func plans(of statements: [String], in store: VaultStore) async throws -> [String] {
    try await store.read { transaction in
      try statements.flatMap { statement in
        try Row.fetchAll(transaction.database, sql: "EXPLAIN QUERY PLAN \(statement)").map { "\(statement) → \($0["detail"] as String)" }
      }
    }
  }
}

private let models: [(name: String, perRecord: Bool, load: Load)] = [
  ("LibraryList", false, { _ = try LibraryList.load((), in: $0) }),
  ("NovelOverview", true, { _ = try NovelOverview.load(readNovel, in: $0) }),
  ("StoryStructure", true, { _ = try StoryStructure.load(readNovel, in: $0) }),
  ("StoryBibleContents", true, { _ = try StoryBibleContents.load(readNovel, in: $0) }),
  ("NotebookContents", true, { _ = try NotebookContents.load(NotebookQuery(novel: readNovel), in: $0) }),
  ("ChapterList", false, { _ = try ChapterList.load(readNovel, in: $0) }),
  ("KnowledgeLedger", false, { _ = try KnowledgeLedger.load(readNovel, in: $0) }),
  ("ChapterHeadings", false, { _ = try ChapterHeadings.load(readNovel, in: $0) }),
]

@Suite("Read model cost", TestTimeLimit.standard)
struct ReadModelCostTests {
  @Test func shouldKeepStatementCountsIndependentOfTheNumberOfChaptersForDerivedModels() async throws {
    let small = try await Scaled.store(records: 4, revisions: 1)
    let large = try await Scaled.store(records: 14, revisions: 1)
    for model in models where !model.perRecord {
      let before = try await Scaled.statements(in: small, model.load)
      let after = try await Scaled.statements(in: large, model.load)
      #expect(!before.isEmpty && before.count == after.count, "\(model.name): \(before.count) vs \(after.count)")
    }
  }

  @Test func shouldReadRecordBackedModelsInProportionToRecordsAndNotToTheirRevisions() async throws {
    let thin = try await Scaled.store(records: 4, revisions: 1)
    let thick = try await Scaled.store(records: 4, revisions: 6)
    let large = try await Scaled.store(records: 14, revisions: 1)
    for model in models where model.perRecord {
      let base = try await Scaled.statements(in: thin, model.load).count
      #expect(try await Scaled.statements(in: thick, model.load).count == base, "\(model.name) reads history")
      let more = try await Scaled.statements(in: large, model.load).count
      #expect(more <= base + 10 * 4 * 3, "\(model.name): \(base) to \(more)")
    }
  }

  @Test func shouldUseIndexesOnly() async throws {
    let store = try await Scaled.store(records: 14, revisions: 2)
    for model in models {
      let statements = try await Scaled.statements(in: store, model.load)
      for line in try await Scaled.plans(of: statements, in: store) where line.contains("→ SCAN") {
        #expect(line.contains(ProjectionFaults.table), "\(model.name) scans: \(line)")
      }
    }
  }
}
