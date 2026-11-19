import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let headingDerivations: [any Derivation] = [ChapterHeadingSourceDerivation(), ChapterHeadingDerivation()]

private enum HeadingWrites {
  static func plan(_ chapter: Int, title: String?, volume: String?, in transaction: inout WriteTransaction) throws {
    var content = planContent(volume: volume)
    content.title = title
    try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, content, in: &transaction)
  }

  static func draft(_ chapter: Int, title: String?, novel: UUID = novel, in transaction: inout WriteTransaction) throws {
    let content = DraftContent(title: title, body: "Prose.", source: .known(.handEdited))
    let record = try DraftRecord(novel: novel, chapter: chapter, content: content)
    switch try DraftRecord.read(record.ref, in: transaction) {
    case .absent: _ = try record.create(in: &transaction)
    case .readable(let entry) where entry.isRemoved:
      _ = try record.restore(in: &transaction)
      _ = try DraftRecord.revise(record.ref, content, in: &transaction)
    default: _ = try DraftRecord.revise(record.ref, content, in: &transaction)
    }
  }

  static func finalize(_ chapter: Int, title: String?, volume: String?, body: String = "Final.", novel: UUID = novel, in transaction: inout WriteTransaction) throws {
    _ = try FinalChapterRecord(novel: novel, chapter: chapter, canon: Canon(draftRevision: "v:draft", title: title, body: body, volume: volume)).finalize(in: &transaction)
  }

  static func amend(_ chapter: Int, title: String?, novel: UUID = novel, in transaction: inout WriteTransaction) throws {
    let ref = try FinalChapterRecord.ref(novel: novel, chapter: chapter)
    guard case .readable = try FinalChapterRecord.read(ref, in: transaction) else { return }
    _ = try FinalChapterRecord.amend(ref, FinalChapterText(title: title, body: "Amended."), in: &transaction)
  }

  static func unreadableFinal(_ chapter: Int, novel: UUID = novel, in transaction: inout WriteTransaction) throws {
    let key = try NovelForgeKey.finalChapterKey(novel: novel, chapter: chapter)
    _ = try transaction.set(key.ref, [CommonField.naturalKey.rawValue: key.stored, FinalChapterField.canon.rawValue: .object(["body": .int(1)])])
  }
}

private func headings(in store: VaultStore) async throws -> [Int: ChapterHeading] {
  try #require(try await store.load(ChapterHeadings.self, novel).headings.value)
}

private func write(_ store: VaultStore, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
  _ = try await Projection.write(store) { transaction in try body(&transaction) }
}

private func seeded() async throws -> VaultStore {
  let store = try Projection.store(try Projection.reconciler())
  try await write(store) { transaction in _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction) }
  return store
}

@Suite("Chapter headings", TestTimeLimit.standard)
struct ChapterHeadingTests {
  @Test func shouldHeadAChapterFromItsPlanThenItsDraftThenItsFinalChapterAndItsBoundAmendment() async throws {
    let store = try await seeded()
    try await write(store) { try HeadingWrites.plan(1, title: "Plan", volume: "one", in: &$0) }
    #expect(try await headings(in: store) == [1: ChapterHeading(title: "Plan", volume: "one")])
    try await write(store) { try HeadingWrites.draft(1, title: "Draft", in: &$0) }
    #expect(try await headings(in: store) == [1: ChapterHeading(title: "Draft", volume: "one")])
    try await write(store) { try HeadingWrites.finalize(1, title: "Canon", volume: "two", in: &$0) }
    #expect(try await headings(in: store) == [1: ChapterHeading(title: "Canon", volume: "two")])
    try await write(store) { try HeadingWrites.amend(1, title: "Amended", in: &$0) }
    #expect(try await headings(in: store) == [1: ChapterHeading(title: "Amended", volume: "two")])
    try await write(store) { try HeadingWrites.amend(1, title: nil, in: &$0) }
    #expect(try await headings(in: store) == [1: ChapterHeading(title: "Draft", volume: "two")])
  }

  @Test func shouldTakeEachFieldFromTheFirstRecordThatNamesIt() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try HeadingWrites.plan(1, title: "Plan one", volume: "one", in: &transaction)
      try HeadingWrites.finalize(1, title: "Canon one", volume: nil, in: &transaction)
      try HeadingWrites.plan(2, title: nil, volume: "two", in: &transaction)
      try HeadingWrites.draft(2, title: "", in: &transaction)
      try HeadingWrites.plan(3, title: nil, volume: nil, in: &transaction)
      try HeadingWrites.draft(3, title: nil, in: &transaction)
    }
    #expect(try await headings(in: store) == [1: ChapterHeading(title: "Canon one", volume: "one"), 2: ChapterHeading(title: "", volume: "two")])
  }

  @Test func shouldFallBackWhileADraftOrPlanIsRemovedAndReturnWhenItIsRestored() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try HeadingWrites.plan(1, title: "Plan", volume: "one", in: &transaction)
      try HeadingWrites.draft(1, title: "Draft", in: &transaction)
    }
    try await write(store) { try ChapterWrites.removeDraft(novel: novel, chapter: 1, in: &$0) }
    #expect(try await headings(in: store) == [1: ChapterHeading(title: "Plan", volume: "one")])
    try await write(store) { _ = try ChapterPlanRecord.remove(try ChapterPlanRecord.ref(novel: novel, chapter: 1), in: &$0) }
    #expect(try await headings(in: store) == [:])
    try await write(store) { try HeadingWrites.draft(1, title: "Back", in: &$0) }
    #expect(try await headings(in: store) == [1: ChapterHeading(title: "Back", volume: nil)])
  }

  @Test func shouldFallBackPastAFinalChapterThatCannotBeReadOrIsPurged() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try HeadingWrites.plan(1, title: "Plan", volume: "one", in: &transaction)
      try HeadingWrites.unreadableFinal(1, in: &transaction)
      try HeadingWrites.plan(2, title: "Plan two", volume: "one", in: &transaction)
      try HeadingWrites.finalize(2, title: "Canon two", volume: "two", in: &transaction)
    }
    #expect(try await headings(in: store) == [1: ChapterHeading(title: "Plan", volume: "one"), 2: ChapterHeading(title: "Canon two", volume: "two")])
    try await write(store) { _ = try $0.purge(try FinalChapterRecord.ref(novel: novel, chapter: 2)) }
    #expect(try await headings(in: store)[2] == ChapterHeading(title: "Plan two", volume: "one"))
  }

  @Test func shouldIgnoreAnAmendmentBoundToAnotherCanon() async throws {
    let store = try await seeded()
    let ref = try FinalChapterRecord.ref(novel: novel, chapter: 1)
    try await write(store) { transaction in
      try HeadingWrites.finalize(1, title: "Canon", volume: nil, in: &transaction)
      try HeadingWrites.amend(1, title: "Bound", in: &transaction)
      _ = try transaction.revise(ref, body: FinalChapterAmendment(canon: "another canon", text: FinalChapterText(title: "Stray", body: "Stray.")).json)
    }
    #expect(try await headings(in: store)[1]?.title == "Bound")
  }

  @Test func shouldHeadEachNovelOnItsOwn() async throws {
    let store = try await seeded()
    let other = SchemaFixture.otherNovel
    try await write(store) { transaction in
      try HeadingWrites.finalize(1, title: "Mine", volume: nil, in: &transaction)
      try HeadingWrites.finalize(1, title: "Theirs", volume: nil, novel: other, in: &transaction)
    }
    #expect(try await headings(in: store) == [1: ChapterHeading(title: "Mine", volume: nil)])
    #expect(try await store.load(ChapterHeadings.self, other).headings.value == [1: ChapterHeading(title: "Theirs", volume: nil)])
  }

  @Test func shouldFollowTheAmendmentOfTheCanonThatWinsOnEveryReplica() async throws {
    let reconciler = try Projection.reconciler(headingDerivations)
    let replicas = try await CausalReplicas(
      CausalReplicaSetup(count: 2, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: 0xD28B))
    for (index, name) in [(0, "First"), (1, "Second")] {
      _ = try await replicas.write(index) { transaction in
        try HeadingWrites.finalize(1, title: name, volume: name, body: name, in: &transaction)
        try HeadingWrites.amend(1, title: "\(name) amended", in: &transaction)
      }
    }
    try await replicas.settle()
    var seen = [ChapterHeading]()
    for index in 0..<2 {
      let store = await replicas.store(index)
      let final = try await store.read { try FinalChapterRecord.read(try FinalChapterRecord.ref(novel: novel, chapter: 1), in: $0).entry?.record }
      let heading = try #require(try await headings(in: store)[1])
      #expect(heading == ChapterHeading(title: final?.text.title, volume: final?.canon.volume))
      seen.append(heading)
    }
    #expect(Set(seen.map(\.title)).count == 1)
    #expect(seen.first?.title?.hasSuffix(" amended") == true)
  }
}

@Suite("Chapter heading faults", TestTimeLimit.standard)
struct ChapterHeadingFaultTests {
  private func faulted(_ derivation: String, key: String) async throws -> ChapterHeadings {
    let store = try Projection.store(try Projection.reconciler(), allowingFaults: true)
    try await write(store) { try HeadingWrites.finalize(1, title: "Canon", volume: nil, in: &$0) }
    try await ReadWorld.insertFault(derivation, key: key, in: store)
    return try await store.load(ChapterHeadings.self, novel)
  }

  @Test(arguments: [ChapterHeadingEntry.databaseTableName, ChapterHeadingSource.databaseTableName])
  func shouldBeUnavailableNotEmptyWhileEitherLayerIsFaultedAsAWhole(table: String) async throws {
    let loaded = try await faulted(table, key: ProjectionFaults.wholeDerivation)
    guard case .unavailable(let faults) = loaded.headings else {
      Issue.record("headings should be unavailable")
      return
    }
    #expect(faults.map(\.derivation) == [table])
  }

  @Test func shouldKeepOtherChaptersWhenOneChapterIsFaulted() async throws {
    let key = ProjectionFaults.key(ChapterHeadingKey(novel: novel, chapter: 2))
    let loaded = try await faulted(ChapterHeadingEntry.databaseTableName, key: key)
    #expect(loaded.headings.value == [1: ChapterHeading(title: "Canon", volume: nil)])
    #expect(loaded.faults.map(\.scope) == [.entry])
  }

  @Test func shouldNotBeBlockedByAnUnrelatedDerivation() async throws {
    let loaded = try await faulted(ChapterLifecycleEntry.databaseTableName, key: ProjectionFaults.wholeDerivation)
    #expect(loaded.headings.value?[1]?.title == "Canon")
    #expect(loaded.faults.isEmpty)
  }
}

private let titles: [String?] = [nil, "", "Ember", "Tide"]
private let volumes: [String?] = [nil, "one", "two"]

enum ChapterHeadingOperations {
  static let all: [ProjectionOperation] = [
    ProjectionOperation(name: "revise a plan's title and volume", weight: 4) { generator, universe in
      let (novel, chapter, title, volume) = (universe.novel(&generator), universe.chapter(&generator), generator.pick(from: titles), generator.pick(from: volumes))
      return { transaction in
        var content = planContent(volume: volume)
        content.title = title
        try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, content, in: &transaction)
      }
    },
    ProjectionOperation(name: "remove a plan", weight: 1) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      return { transaction in _ = try ChapterPlanRecord.remove(try ChapterPlanRecord.ref(novel: novel, chapter: chapter), in: &transaction) }
    },
    ProjectionOperation(name: "write a draft title", weight: 4) { generator, universe in
      let (novel, chapter, title) = (universe.novel(&generator), universe.chapter(&generator), generator.pick(from: titles))
      return { transaction in try HeadingWrites.draft(chapter, title: title, novel: novel, in: &transaction) }
    },
    ProjectionOperation(name: "remove a draft", weight: 1) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      return { transaction in try ChapterWrites.removeDraft(novel: novel, chapter: chapter, in: &transaction) }
    },
    ProjectionOperation(name: "write an unreadable draft or plan head", weight: 1) { generator, universe in
      let (novel, chapter, isDraft) = (universe.novel(&generator), universe.chapter(&generator), generator.chance(0.5))
      return { transaction in
        let ref = isDraft ? try DraftRecord.ref(novel: novel, chapter: chapter) : try ChapterPlanRecord.ref(novel: novel, chapter: chapter)
        _ = try transaction.revise(ref, body: .object(["body": .int(1)]))
      }
    },
    ProjectionOperation(name: "finalize with a title and volume", weight: 3) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      let (title, volume, body) = (generator.pick(from: titles), generator.pick(from: volumes), universe.text(&generator))
      return { transaction in try HeadingWrites.finalize(chapter, title: title, volume: volume, body: body, novel: novel, in: &transaction) }
    },
    ProjectionOperation(name: "amend a final chapter's title", weight: 3) { generator, universe in
      let (novel, chapter, title) = (universe.novel(&generator), universe.chapter(&generator), generator.pick(from: titles))
      return { transaction in try HeadingWrites.amend(chapter, title: title, novel: novel, in: &transaction) }
    },
    ProjectionOperation(name: "amend another canon", weight: 1) { generator, universe in
      let (novel, chapter, title) = (universe.novel(&generator), universe.chapter(&generator), generator.pick(from: titles))
      return { transaction in
        let amendment = FinalChapterAmendment(canon: "another canon", text: FinalChapterText(title: title, body: "Stray."))
        _ = try transaction.revise(try FinalChapterRecord.ref(novel: novel, chapter: chapter), body: amendment.json)
      }
    },
    ProjectionOperation(name: "write an unreadable final chapter", weight: 1) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      return { transaction in try HeadingWrites.unreadableFinal(chapter, novel: novel, in: &transaction) }
    },
    ProjectionOperation(name: "purge a chapter's record", weight: 1) { generator, universe in
      let (novel, chapter, kind) = (universe.novel(&generator), universe.chapter(&generator), generator.int(in: 0...2))
      return { transaction in
        let ref =
          switch kind {
          case 0: try FinalChapterRecord.ref(novel: novel, chapter: chapter)
          case 1: try DraftRecord.ref(novel: novel, chapter: chapter)
          default: try ChapterPlanRecord.ref(novel: novel, chapter: chapter)
          }
        _ = try transaction.purge(ref)
      }
    },
  ]
}

private final class HeadingCoverage: Sendable {
  let seen = Mutex(Set<String>())
}

// The reading `ChapterOutline` made before the derivation existed: whole records, chapter by chapter.
private func expectedHeadings(_ universe: ProjectionUniverse, in transaction: ReadTransaction) throws -> [ChapterHeadingEntry] {
  var entries = [ChapterHeadingEntry]()
  for novel in universe.novels {
    for chapter in universe.chapters {
      var title: String?
      var volume: String?
      if case .readable(let entry) = try FinalChapterRecord.read(try FinalChapterRecord.ref(novel: novel, chapter: chapter), in: transaction), !entry.isRemoved {
        title = entry.record.text.title
        volume = entry.record.canon.volume
      }
      if title == nil, case .readable(let entry) = try DraftRecord.read(try DraftRecord.ref(novel: novel, chapter: chapter), in: transaction), !entry.isRemoved {
        title = entry.record.content.title
      }
      if case .readable(let entry) = try ChapterPlanRecord.read(try ChapterPlanRecord.ref(novel: novel, chapter: chapter), in: transaction), !entry.isRemoved {
        title = title ?? entry.record.content.title
        volume = volume ?? entry.record.content.volume
      }
      if title != nil || volume != nil { entries.append(ChapterHeadingEntry(novel: novel, chapter: chapter, title: title, volume: volume)) }
    }
  }
  return entries
}

private func oracle(_ coverage: HeadingCoverage) -> @Sendable (NovelForgeReconciler, VaultStore, ProjectionUniverse) async throws -> Void {
  { _, store, universe in
    let (expected, finals) = try await store.read { transaction in
      let finals = try FinalChapterRecord.listing(in: transaction).entries.map(\.record)
      return (try expectedHeadings(universe, in: transaction), finals)
    }
    let actual = try await Projection.fetch(ChapterHeadingEntry.all(), in: store)
    guard Set(actual) == Set(expected), actual.count == expected.count else {
      throw ProjectionPropertyFailure.oracle("headings \(actual) differ from \(expected)")
    }
    var facts = Set<String>()
    for entry in actual {
      let final = finals.first { $0.novel == entry.novel && $0.chapter == entry.chapter }
      if let final, final.amendment != nil, entry.title == final.text.title, entry.title != nil { facts.insert("amended title") }
      if let final, final.canon.volume == nil, entry.volume != nil { facts.insert("plan volume under a canon") }
      if let final, final.text.title == nil, entry.title != nil { facts.insert("title under an untitled canon") }
      if entry.title == "" { facts.insert("empty title") }
      if entry.title == nil { facts.insert("volume only") }
    }
    coverage.seen.withLock { $0.formUnion(facts) }
  }
}

@Suite("Chapter heading projection property", TestTimeLimit.property)
struct ChapterHeadingPropertyTests {
  @Test(arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldMatchARebuildAtEveryStepAndAgreeWithTheOracleOnEveryReplica(order: CausalReplicaOrder) async throws {
    let coverage = HeadingCoverage()
    let property = ProjectionProperty(
      derivations: headingDerivations, operations: ChapterHeadingOperations.all, iterations: 12, steps: 36, settled: oracle(coverage))
    try await property.check(order: order, seed: order == .causal ? 0xD28B1 : 0xD28B2)
  }

  @Test func shouldMatchARebuildAlongsideTheWholeChapterArea() async throws {
    let property = ProjectionProperty(
      derivations: chapterAreaDerivations, operations: ChapterOperations.all + ChapterHeadingOperations.all, iterations: 3, steps: 32,
      settled: oracle(HeadingCoverage()))
    try await property.check(order: .causal, seed: 0xD28B3)
  }

  @Test(.enabled(if: ProjectionProperty.scale > 1, "a check of the generator, not of the derivation: NOVELFORGE_PROPERTY_SCALE=2 swift test"))
  func shouldReachEveryInterestingState() async throws {
    let coverage = HeadingCoverage()
    let property = ProjectionProperty(
      derivations: headingDerivations, operations: ChapterHeadingOperations.all, iterations: 24, steps: 30, checksEveryStep: false, settled: oracle(coverage))
    try await property.check(order: .causal, seed: 0xD28B4)
    let expected: Set<String> = ["amended title", "plan volume under a canon", "title under an untitled canon", "empty title", "volume only"]
    #expect(expected.subtracting(coverage.seen.withLock { $0 }) == [])
  }
}
