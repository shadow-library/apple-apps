import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private struct ReaderDisclosureFixture: Decodable {
  struct Volume: Decodable {
    let volume: String
    let ordinal: Int
  }

  struct Term: Decodable {
    let milestone: String?
    let volume: String?
    let chapter: Int?
    let ending: Bool?

    var json: JSONValue {
      if let milestone { return PlanWorldTerm.milestone(milestone).json }
      if let volume { return PlanWorldTerm.volume(volume).json }
      if let chapter { return PlanWorldTerm.chapter(chapter).json }
      return PlanWorldTerm.ending.json
    }
  }

  struct Fact: Decodable {
    let fact: String
    let revealChapter: Int?
    let unlock: [Term]?
    let source: String
    let createdAfter: Int
  }

  struct Learned: Decodable {
    let entity: String
    let fact: String
  }

  struct Plan: Decodable {
    let chapter: Int
    let volume: String?
    let ending: Bool
    let claims: [String]
    let pov: [String]
    let learns: [Learned]

    var contract: ChapterContract {
      NovelForgeCoreTests.contract(pov: pov, learns: learns.map { Learn($0.entity, $0.fact) }, claims: claims, ending: ending)
    }
  }

  struct Case: Decodable {
    let volumes: [Volume]
    let milestones: [String]
    let facts: [Fact]
    let plans: [Plan]
    let finals: Int
    let finalized: Int
    let expected: [String: Int]
  }

  let cases: [Case]
}

private func seed(_ fixture: ReaderDisclosureFixture.Case, novel: UUID, in transaction: inout WriteTransaction) throws {
  _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
  for volume in fixture.volumes { try PlanWorldWrites.volume(novel: novel, volume.volume, ordinal: volume.ordinal, in: &transaction) }
  for milestone in fixture.milestones { try PlanWorldWrites.milestone(novel: novel, milestone, in: &transaction) }
  for plan in fixture.plans { try PlanWorldWrites.putPlan(novel: novel, chapter: plan.chapter, planContent(volume: plan.volume, plan.contract), in: &transaction) }
}

/// A novel of the fixture on its way through its chapters; `stopped` once a chapter is refused, as the reference stops at it.
private struct Book {
  let fixture: ReaderDisclosureFixture.Case
  let novel: UUID
  var finalized = 0
  var stopped = false
  var head: String?

  var next: Int? { !stopped && finalized < fixture.finals ? finalized + 1 : nil }
}

/// What `done` finals later the reference held, the secrets created by then, and the next chapter drafted, approved and finalized through the domain operations.
private func step(_ done: Int, _ books: [Book], in store: VaultStore) async throws -> [Book] {
  let now = store.wallClock()
  let drafted = try await Projection.write(store) { transaction in
    var books = books
    for index in books.indices {
      for fact in books[index].fixture.facts where fact.createdAfter == done && books[index].finalized == done {
        guard let source = FactSource(rawValue: fact.source) else { throw ProjectionPropertyFailure.oracle("unknown source \(fact.source)") }
        let unlock = fact.unlock.map { JSONValue.object(["all": .array($0.map(\.json))]) }
        try PlanWorldWrites.secret(novel: books[index].novel, fact.fact, revealChapter: fact.revealChapter, unlock: unlock, source: source, in: &transaction)
      }
      guard let chapter = books[index].next else { continue }
      let edit = DraftEdit(body: "Chapter \(chapter).", summary: "It turns.")
      books[index].head = try ChapterDrafts.save(novel: books[index].novel, chapter: chapter, edit, base: nil, at: now, in: &transaction).base
    }
    return books
  }
  let replica = store.replica
  let approved = try await Projection.write(store) { transaction in
    var books = drafted
    for index in books.indices {
      guard let chapter = books[index].next, let head = books[index].head else { continue }
      do throws(DomainError) {
        try ChapterApprovals.approve(novel: books[index].novel, chapter: chapter, revision: head, requester: replica, in: &transaction)
      } catch {
        books[index].stopped = true
      }
    }
    return books
  }
  return try await Projection.write(store) { transaction in
    var books = approved
    for index in books.indices {
      guard let chapter = books[index].next else { continue }
      do throws(DomainError) {
        try ChapterFinalize.finalize(novel: books[index].novel, chapter: chapter, in: &transaction)
        books[index].finalized = chapter
      } catch {
        books[index].stopped = true
      }
    }
    return books
  }
}

/// The reference's tables when chapter `chapter` is finalized: the secrets created by then, every plan, and the milestones the chapters before it reached.
private func referenceWorld(_ fixture: ReaderDisclosureFixture.Case, finalizing chapter: Int) -> DisclosureWorld {
  let facts = fixture.facts.filter { $0.createdAfter < chapter }.map { fact in
    let unlock = fact.unlock.map { terms in UnlockCondition(validating: OrderedJSON(.object(["all": .array(terms.map(\.json))]))).map(FactUnlock.condition) ?? .unreadable }
    return DisclosureFact(factKey: fact.fact, text: "", source: FactSource(rawValue: fact.source), revealChapter: fact.revealChapter, unlock: unlock)
  }
  let plans = fixture.plans.map { plan in
    let learns = plan.learns.map { learn in
      OrderedJSON.object(OrderedJSONObject([(key: "entityKey", value: .string(learn.entity)), (key: "factKey", value: .string(learn.fact))]))
    }
    let contract = OrderedJSON.object(OrderedJSONObject([(key: "pov", value: .array(plan.pov.map(OrderedJSON.string))), (key: "learns", value: .array(learns))]))
    let claims = PlanClaims(chapter: plan.chapter, volumeKey: plan.volume, isEnding: plan.ending, claimedMilestones: plan.claims)
    return DisclosurePlan(normalizing: claims, knowledgeContract: contract, endingContract: .null)
  }
  let milestones = fixture.milestones.map { key in
    let reached = fixture.plans.filter { $0.chapter < chapter && $0.claims.contains(key) }.map(\.chapter).min()
    return MilestoneRow(milestoneKey: key, state: reached == nil ? .open : .reached, reachedChapter: reached)
  }
  return DisclosureWorld(
    facts: facts, plans: plans, milestones: milestones, volumes: fixture.volumes.map { DisclosureVolume(volumeKey: $0.volume, ordinal: $0.ordinal) })
}

@Suite("Reader disclosure parity with the reference", TestTimeLimit.standard)
struct ReaderDisclosureParityTests {
  @Test func shouldComputeWhatEachChapterDisclosesAtFinalizeAsTheReferenceDoesInEveryWorld() throws {
    let fixture = try ReferenceFixture.decode(ReaderDisclosureFixture.self, from: "reader-disclosure/disclosure.json")
    #expect(fixture.cases.count == 300)
    for (offset, world) in fixture.cases.enumerated() {
      var disclosed = [JSString: Int]()
      for chapter in stride(from: 1, through: world.finalized, by: 1) {
        for key in referenceWorld(world, finalizing: chapter).chapterReveals(chapter: chapter) where disclosed[JSString(key)] == nil { disclosed[JSString(key)] = chapter }
      }
      let expected = Dictionary(uniqueKeysWithValues: world.expected.map { (JSString($0.key), $0.value) })
      #expect(disclosed == expected, "case \(offset)")
    }
  }

  /// Every third world by default, every world with `NOVELFORGE_PROPERTY_SCALE` of 2 or more.
  @Test(arguments: 0..<4)
  func shouldDiscloseWhatTheReferenceDisclosesWhenItFinalizesChapterByChapter(shard: Int) async throws {
    let fixture = try ReferenceFixture.decode(ReaderDisclosureFixture.self, from: "reader-disclosure/disclosure.json")
    let unread: [any Derivation.Type] = [CharacterKnowledgeDerivation.self, ChapterHeadingSourceDerivation.self, ChapterHeadingDerivation.self]
    let derivations = chapterAreaDerivations.filter { derivation in !unread.contains { $0 == type(of: derivation) } }
    let store = try Projection.store(try Projection.reconciler(derivations))
    let cases = fixture.cases.enumerated().filter { $0.offset % 4 == shard && (ProjectionProperty.scale > 1 || $0.offset % 3 == 0) }
    var books = cases.map { Book(fixture: $0.element, novel: UUID()) }
    let seeded = books
    _ = try await Projection.write(store) { transaction in
      for book in seeded { try seed(book.fixture, novel: book.novel, in: &transaction) }
    }
    for done in 0...8 { books = try await step(done, books, in: store) }
    for ((offset, fixture), book) in zip(cases, books) {
      #expect(book.finalized == fixture.finalized, "case \(offset)")
      let disclosed = try await Projection.fetch(ReaderDisclosureDerivation.request(for: book.novel), in: store)
      let actual = Dictionary(uniqueKeysWithValues: disclosed.map { (Array($0.secret.utf16), $0.chapter) })
      let expected = Dictionary(uniqueKeysWithValues: fixture.expected.map { (Array($0.key.utf16), $0.value) })
      #expect(actual == expected, "case \(offset)")
    }
  }
}
