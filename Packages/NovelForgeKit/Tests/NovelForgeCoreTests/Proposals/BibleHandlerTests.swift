import Foundation
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

enum UndoRoute: Sendable {
  case bible
  case plan
}

extension ChapterBook {
  /// An inverse written back through the frame by the bible or plan undo entry point, its refs named by the call it undoes.
  func undo(_ inverse: OrderedJSONObject?, of call: ContentCall, through route: UndoRoute) async throws -> DraftApplyResult {
    let context = applyContext(.undo)
    let inverse = try #require(inverse)
    return try await run { transaction in
      do throws(ApplyError) {
        let step = try ApplyFrame.perform(call, context: context, in: &transaction) { _, context, transaction throws(ApplyError) in
          switch route {
          case .bible: try BibleHandlers.undo(inverse, context: context, in: &transaction)
          case .plan: try PlanHandlers.undo(inverse, context: context, in: &transaction)
          }
        }
        return .success(step)
      } catch {
        return .failure(error)
      }
    }
  }

  func page(_ section: BiblePageSection, _ slug: String) async throws -> PageRecord? {
    let novel = novel
    return try await store.read { try Pages.get(novel: novel, section: section, slug: slug, in: $0) }
  }

  func pageRevisions(_ section: BiblePageSection, _ slug: String) async throws -> Int {
    let novel = novel
    return try await store.read { try PageRecord.history(novel: novel, section: section, slug: slug, in: $0).history?.revisions.count ?? 0 }
  }

  func entity(_ key: String) async throws -> EntityRecord? {
    let novel = novel
    return try await store.read { try Entities.get(novel: novel, entity: key, in: $0) }
  }
}

func inverseObject(_ text: String) throws -> OrderedJSONObject {
  try #require(try OrderedJSON(parsing: text).objectValue)
}

/// Apply, undo, redo and undo again through the frame: each undo lands on the content hash the apply found, each redo on the one the apply left.
func expectContentRoundTrip(_ book: ChapterBook, _ call: ContentCall, through route: UndoRoute, sourceLocation: SourceLocation = #_sourceLocation) async throws {
  let applied = try await book.perform(call).get()
  #expect(applied.priorState != applied.postState, sourceLocation: sourceLocation)
  let undone = try await book.undo(applied.inverse, of: call, through: route).get()
  #expect(undone.priorState == applied.postState, sourceLocation: sourceLocation)
  #expect(undone.postState == applied.priorState, sourceLocation: sourceLocation)
  let redone = try await book.perform(call, intent: .redo).get()
  #expect(redone.priorState == applied.priorState, sourceLocation: sourceLocation)
  #expect(redone.postState == applied.postState, sourceLocation: sourceLocation)
  let again = try await book.undo(redone.inverse, of: call, through: route).get()
  #expect(again.postState == applied.priorState, sourceLocation: sourceLocation)
}

private let world = BiblePageSection.world

// apps/novel-forge-server/src/modules/refinement/apply/bible-document.handler.ts, entity.handler.ts and tests/refinement/proposal-apply-op-undo.spec.ts
@Suite("Bible handlers", TestTimeLimit.standard)
struct BibleHandlerTests {
  // bible-document.handler.ts:27-33
  @Test func shouldCreateAPageAsGivenWithoutDerivingATitle() async throws {
    let book = try await ChapterBook.make()
    let step = try await book.perform(try draftCall(##"{"op":"bible_document.upsert","section":"world","slug":"city","body":"# The Drowned City\nBells."}"##)).get()
    let page = try #require(try await book.page(world, "city"))
    #expect(page.content.frontmatter == nil)
    #expect(page.content.body == "# The Drowned City\nBells.")
    #expect(step.result == nil)
    #expect(step.planEdits.isEmpty)
    #expect(step.inverse == (try inverseObject(#"{"op":"bible_document.remove","section":"world","slug":"city"}"#)))
  }

  // bible-document.handler.ts:36: an undefined column drops out of the upsert's set
  @Test func shouldKeepTheFrontmatterOrBodyAnUpsertLeavesOutOfAnExistingPage() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { _ = try Pages.create(novel: novel, section: world, slug: "city", frontmatter: ["title": "City"], body: "Old.", in: &$0) }
    let step = try await book.perform(try draftCall(#"{"op":"bible_document.upsert","section":"world","slug":"city","body":"New."}"#)).get()
    #expect(try await book.page(world, "city")?.content == PageContent(frontmatter: ["title": "City"], body: "New."))
    #expect(step.inverse == (try inverseObject(#"{"op":"bible_document.upsert","section":"world","slug":"city","frontmatter":{"title":"City"},"body":"Old."}"#)))
    _ = try await book.perform(try draftCall(#"{"op":"bible_document.upsert","section":"world","slug":"city","frontmatter":{"tags":["port"]}}"#)).get()
    #expect(try await book.page(world, "city")?.content == PageContent(frontmatter: ["tags": .array(["port"])], body: "New."))
  }

  // bible-document.handler.ts:37 (setWhere)
  @Test func shouldWriteNoRevisionForAPageTheUpsertLeavesAsItWas() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { _ = try Pages.create(novel: novel, section: world, slug: "city", frontmatter: ["title": "City"], body: "Old.", in: &$0) }
    let before = try await book.pageRevisions(world, "city")
    let step = try await book.perform(try draftCall(#"{"op":"bible_document.upsert","section":"world","slug":"city","body":"Old."}"#)).get()
    #expect(try await book.pageRevisions(world, "city") == before)
    #expect(step.priorState == step.postState)
  }

  @Test func shouldWriteATextThatDiffersOnlyInItsUnicodeFormAsAChange() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { _ = try Pages.create(novel: novel, section: world, slug: "city", frontmatter: ["title": "City"], body: "caf\u{e9}", in: &$0) }
    let step = try await book.perform(try draftCall(#"{"op":"bible_document.upsert","section":"world","slug":"city","body":"café"}"#)).get()
    #expect(step.priorState != step.postState)
    #expect(try await book.page(world, "city")?.content.body?.jsEquals("cafe\u{301}") == true)
  }

  // bible-document.handler.ts:60
  @Test func shouldRefuseRemovingAPageThatIsNotThereAsDOC001() async throws {
    let book = try await ChapterBook.make()
    let outcome = try await book.perform(try draftCall(#"{"op":"bible_document.remove","section":"world","slug":"city"}"#))
    #expect(throws: ApplyError.domain(.documentNotFound(section: "world", slug: "city"))) { try outcome.get() }
  }

  @Test func shouldRefuseAFrontmatterNoStoreValueCanHold() async throws {
    let book = try await ChapterBook.make()
    let outcome = try await book.perform(try draftCall(#"{"op":"bible_document.upsert","section":"world","slug":"city","frontmatter":{"weight":1.5}}"#))
    #expect(applyRefusal(outcome) == .unstorable(field: "frontmatter"))
    #expect(try await book.page(world, "city") == nil)
  }

  @Test(arguments: [
    #"{"op":"bible_document.upsert","section":"world","slug":"harbour","body":"Gulls."}"#,
    #"{"op":"bible_document.upsert","section":"world","slug":"city","frontmatter":{"title":"Port"},"body":"New."}"#,
    #"{"op":"bible_document.upsert","section":"world","slug":"city","frontmatter":{"order":2}}"#,
    #"{"op":"bible_document.remove","section":"world","slug":"city"}"#,
  ])
  func shouldRestoreThePageContentThroughApplyUndoRedoUndo(_ json: String) async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { _ = try Pages.create(novel: novel, section: world, slug: "city", frontmatter: ["title": "City"], body: "Old.", in: &$0) }
    try await expectContentRoundTrip(book, try draftCall(json), through: .bible)
  }

  @Test func shouldBringARemovedPageBackWithoutANewVersion() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { _ = try Pages.create(novel: novel, section: world, slug: "city", frontmatter: ["title": "City"], body: "Old.", in: &$0) }
    try await book.run { _ = try Pages.revise(novel: novel, section: world, slug: "city", frontmatter: ["title": "City"], body: "Newer.", in: &$0) }
    let call = try draftCall(#"{"op":"bible_document.remove","section":"world","slug":"city"}"#)
    let removed = try await book.perform(call).get()
    #expect(try await book.page(world, "city") == nil)
    _ = try await book.undo(removed.inverse, of: call, through: .bible).get()
    #expect(try await book.page(world, "city")?.content == PageContent(frontmatter: ["title": "City"], body: "Newer."))
    #expect(try await book.pageRevisions(world, "city") == 2)
  }

  @Test func shouldStartAPageAnApplyWritesOverARemovedOneAfresh() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { transaction in
      _ = try Pages.create(novel: novel, section: world, slug: "city", frontmatter: ["title": "City"], body: "Old.", in: &transaction)
      try Pages.remove(novel: novel, section: world, slug: "city", in: &transaction)
    }
    let call = try draftCall(#"{"op":"bible_document.upsert","section":"world","slug":"city","body":"Again."}"#)
    let step = try await book.perform(call).get()
    #expect(try await book.page(world, "city")?.content == PageContent(body: "Again."))
    #expect(step.inverse == (try inverseObject(#"{"op":"bible_document.remove","section":"world","slug":"city"}"#)))
    try await expectContentRoundTrip(book, try draftCall(#"{"op":"bible_document.upsert","section":"world","slug":"city","body":"Once more."}"#), through: .bible)
  }

  // entity.handler.ts:30
  @Test(arguments: [#"{"op":"entity.upsert","entityKey":"ada","type":"character"}"#, #"{"op":"entity.upsert","entityKey":"ada","type":"character","name":""}"#])
  func shouldRefuseANewEntityWithoutAName(_ json: String) async throws {
    let book = try await ChapterBook.make()
    #expect(applyRefusal(try await book.perform(try draftCall(json))) == .notAllowed)
    #expect(try await book.entity("ada") == nil)
  }

  // entity.handler.ts:47 and proposal-apply-op-undo.spec.ts:19
  @Test func shouldCreateAGeneratedEntityWhoseUndoRemovesIt() async throws {
    let book = try await ChapterBook.make()
    let step = try await book.perform(try draftCall(#"{"op":"entity.upsert","entityKey":"ren","type":"character","name":"Ren","notes":"Waits below."}"#)).get()
    let ren = try #require(try await book.entity("ren"))
    #expect(ren.name == "Ren")
    #expect(ren.notes == "Waits below.")
    #expect(ren.origin == .known(.generated))
    #expect(step.inverse == (try inverseObject(#"{"op":"entity.remove","entityKey":"ren"}"#)))
  }

  // proposal-apply-op-undo.spec.ts:105, :120, :186: an edit keeps the name it leaves out, its undo empties what it filled, its redo fills it again
  @Test func shouldEditOnlyTheFieldsTheOpNamesAndPutThemBackOnUndo() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { try Entities.create(novel: novel, entity: "ada", type: .character, name: "Ada", EntityDetails(notes: "Ada hides the slip."), in: &$0) }
    let json = #"{"op":"entity.upsert","entityKey":"ada","type":"character","notes":"Ada keeps the slip in her boot.","motivation":"She wants the ledger back."}"#
    let call = try draftCall(json)
    let applied = try await book.perform(call).get()
    #expect(try await book.entity("ada")?.name == "Ada")
    #expect(try await book.entity("ada")?.motivation == "She wants the ledger back.")
    let restore = #"{"op":"entity.upsert","entityKey":"ada","type":"character","name":"Ada","status":null,"motivation":null,"notes":"Ada hides the slip.","body":null}"#
    #expect(applied.inverse == (try inverseObject(restore)))
    _ = try await book.undo(applied.inverse, of: call, through: .bible).get()
    let undone = try #require(try await book.entity("ada"))
    #expect(undone.notes == "Ada hides the slip.")
    #expect(undone.motivation == nil)
    _ = try await book.perform(call, intent: .redo).get()
    #expect(try await book.entity("ada")?.notes == "Ada keeps the slip in her boot.")
  }

  // entity.handler.ts:33
  @Test func shouldTakeTheTypeTheOpNames() async throws {
    let book = try await ChapterBook.make()
    let call = try draftCall(#"{"op":"entity.upsert","entityKey":"mara","type":"faction"}"#)
    let applied = try await book.perform(call).get()
    #expect(try await book.entity("mara")?.type == .known(.faction))
    #expect(try await book.entity("mara")?.name == "Mara")
    _ = try await book.undo(applied.inverse, of: call, through: .bible).get()
    #expect(try await book.entity("mara")?.type == .known(.character))
  }

  // entity.handler.ts:57
  @Test func shouldRefuseRemovingAnEntityThatIsNotThereAsRFN004() async throws {
    let book = try await ChapterBook.make()
    #expect(applyRefusal(try await book.perform(try draftCall(#"{"op":"entity.remove","entityKey":"ada"}"#))) == .notAllowed)
  }

  @Test func shouldBringARemovedEntityBackWithWhatTheInverseDoesNotName() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { try Entities.create(novel: novel, entity: "ada", type: .character, name: "Ada", EntityDetails(significance: .major, appearance: "Tall."), in: &$0) }
    let call = try draftCall(#"{"op":"entity.remove","entityKey":"ada"}"#)
    let removed = try await book.perform(call).get()
    #expect(try await book.entity("ada") == nil)
    _ = try await book.undo(removed.inverse, of: call, through: .bible).get()
    let ada = try #require(try await book.entity("ada"))
    #expect(ada.appearance == "Tall.")
    #expect(ada.significance == .known(.major))
  }

  // entity.handler.ts:47: a removed key the chat names again is inserted anew
  @Test func shouldCreateAnEntityAnApplyWritesOverARemovedOneAfresh() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { transaction in
      try Entities.create(novel: novel, entity: "ada", type: .character, name: "Ada", EntityDetails(origin: .seeded, appearance: "Tall."), in: &transaction)
      try Entities.remove(novel: novel, entity: "ada", in: &transaction)
    }
    _ = try await book.perform(try draftCall(#"{"op":"entity.upsert","entityKey":"ada","type":"character","name":"Ada"}"#)).get()
    let ada = try #require(try await book.entity("ada"))
    #expect(ada.appearance == nil)
    #expect(ada.origin == .known(.generated))
  }

  @Test(arguments: [
    #"{"op":"entity.upsert","entityKey":"ren","type":"character","name":"Ren"}"#,
    #"{"op":"entity.upsert","entityKey":"mara","type":"location","name":"Mara Hold","status":"Ruined","body":"Stones."}"#,
    #"{"op":"entity.remove","entityKey":"mara"}"#,
  ])
  func shouldRestoreTheEntityContentThroughApplyUndoRedoUndo(_ json: String) async throws {
    try await expectContentRoundTrip(try await ChapterBook.make(), try draftCall(json), through: .bible)
  }

  @Test(arguments: [
    #"{"op":"entity.upsert","entityKey":"ada"}"#, #"{"op":"draft.update","chapter":1,"body":"x"}"#, #"{"op":"bible_document.upsert","section":"nowhere","slug":"x","body":null}"#,
    #"{"op":"bible_document.upsert","section":"world","slug":"x","body":"y"}"#,
  ])
  func shouldRefuseAnInverseItCannotRead(_ json: String) async throws {
    let book = try await ChapterBook.make()
    let outcome = try await book.undo(try inverseObject(json), of: try draftCall(#"{"op":"entity.remove","entityKey":"mara"}"#), through: .bible)
    #expect(applyRefusal(outcome) == .malformedInverse)
    #expect(try await book.entity("mara") != nil)
  }

  @Test func shouldRefuseARecordItCannotReadBeforeWritingAnything() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let key = NovelForgeKey.entityKey(novel: novel, entity: "ghost")
    try await book.run { _ = try $0.set(key.ref, ["natural_key": key.stored, "removed": .bool(false)]) }
    let context = book.applyContext()
    let operation = try #require(try applyOps(#"{"op":"entity.upsert","entityKey":"ghost","type":"character","name":"Ghost"}"#).first).operation
    let outcome: (Result<HandlerOutcome, ApplyError>, Int) = try await book.store.write { transaction in
      do throws(ApplyError) {
        return (.success(try BibleHandlers.apply(operation, context: context, in: &transaction)), transaction.changes.count)
      } catch {
        return (.failure(error), transaction.changes.count)
      }
    }
    #expect(throws: ApplyError.unreadable(ref: "entity:ghost")) { try outcome.0.get() }
    #expect(outcome.1 == 0)
  }

  @Test func shouldRestoreAnEntityAnApplyRecreatesOverItsRemovalThroughApplyUndoRedoUndo() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { transaction in
      try Entities.create(novel: novel, entity: "ada", type: .character, name: "Ada", EntityDetails(appearance: "Tall."), in: &transaction)
      try Entities.remove(novel: novel, entity: "ada", in: &transaction)
    }
    try await expectContentRoundTrip(book, try draftCall(#"{"op":"entity.upsert","entityKey":"ada","type":"faction","name":"The Ada"}"#), through: .bible)
  }

  // entity.service.ts and Entities.create refuse these on the author's path, so the chat cannot write them either
  @Test(arguments: [
    #"{"op":"bible_document.upsert","section":"world","slug":"","body":"x"}"#, #"{"op":"bible_document.remove","section":"world","slug":""}"#,
    #"{"op":"entity.upsert","entityKey":"","type":"character","name":"X"}"#, #"{"op":"entity.remove","entityKey":""}"#,
    #"{"op":"entity.upsert","entityKey":"ada","type":"character","name":"  "}"#, #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"　\n"}"#,
  ])
  func shouldRefuseAnEmptyKeyOrABlankNameBeforeWritingAnything(_ json: String) async throws {
    let book = try await ChapterBook.make()
    let call = try unvalidatedCall(json)
    let context = book.applyContext()
    let outcome: (Result<AppliedStep, ApplyError>, Int) = try await book.store.write { transaction in
      do throws(ApplyError) {
        return (.success(try ApplyFrame.perform(call, context: context, in: &transaction)), transaction.changes.count)
      } catch {
        return (.failure(error), transaction.changes.count)
      }
    }
    #expect(applyRefusal(outcome.0) == .notAllowed)
    #expect(outcome.1 == 0)
    #expect(try await book.entity("mara")?.name == "Mara")
  }

  @Test func shouldRefuseAFrontmatterWhoseKeysDifferOnlyInTheirUnicodeForm() async throws {
    let book = try await ChapterBook.make()
    let outcome = try await book.perform(try draftCall(#"{"op":"bible_document.upsert","section":"world","slug":"city","frontmatter":{"café":1,"café":2}}"#))
    #expect(applyRefusal(outcome) == .unstorable(field: "frontmatter"))
    #expect(try await book.page(world, "city") == nil)
  }
}

/// An op built from its fields without the change-set validation, as a stored op that predates a rule reaches a handler.
private func unvalidatedCall(_ json: String) throws -> ContentCall {
  let fields = OpFields(record: try inverseObject(json))
  let type = try #require(fields.string("op").flatMap { OpType(exactly: $0) })
  let operation = try #require(ChangeOperation(type: type, fields: fields))
  return .op(ChangeOp(operation: operation, metadata: OpMetadata(fields)))
}

// The members every handler's inverse is read through: a value the vault cannot hold exactly is malformed, never collapsed
@Suite("Apply handler support", TestTimeLimit.standard)
struct ApplyHandlerSupportTests {
  @Test func shouldRefuseAStoryInverseWhoseUnlockKeysDifferOnlyInTheirUnicodeForm() async throws {
    let book = try await ChapterBook.make()
    let json = #"""
      {"op":"fact.upsert","factKey":"tide","body":"The ledger is forged.","subjects":null,"constraintNote":null,"writerNote":null,"terms":null,
       "revealChapter":5,"unlock":{"all":[],"café":1,"café":2},"allowedClues":null}
      """#
    let inverse = try inverseObject(json)
    let context = book.applyContext(.undo)
    let outcome: Result<HandlerOutcome, ApplyError> = try await book.store.write { transaction in
      do throws(ApplyError) {
        return .success(try StoryHandlers.undo(inverse, context: context, in: &transaction))
      } catch {
        return .failure(error)
      }
    }
    #expect(throws: ApplyError.refused(.malformedInverse)) { try outcome.get() }
  }

  @Test func shouldNameAStoryRecordItCannotReadByItsArtifactRef() async throws {
    let book = try await ChapterBook.make()
    let key = NovelForgeKey.volumeKey(novel: book.novel, volume: "broken")
    try await book.run { _ = try $0.set(key.ref, ["natural_key": key.stored, "removed": .bool(false)]) }
    let operation = try #require(try applyOps(#"{"op":"volume.remove","volumeKey":"broken"}"#).first).operation
    let context = book.applyContext()
    let outcome: (Result<HandlerOutcome, ApplyError>, Int) = try await book.store.write { transaction in
      do throws(ApplyError) {
        return (.success(try StoryHandlers.apply(operation, context: context, in: &transaction)), transaction.changes.count)
      } catch {
        return (.failure(error), transaction.changes.count)
      }
    }
    #expect(throws: ApplyError.unreadable(ref: "volume:broken")) { try outcome.0.get() }
    #expect(outcome.1 == 0)
  }

  @Test func shouldHoldIntegersAndRefuseFractionsAndCollapsingKeys() throws {
    #expect(storableObject(try OrderedJSON(parsing: #"{"a":1,"b":[true,null,"x"]}"#)) == ["a": 1, "b": .array([true, .null, "x"])])
    #expect(storableObject(try OrderedJSON(parsing: #"{"a":1.5}"#)) == nil)
    #expect(storableObject(try OrderedJSON(parsing: #"{"café":1,"café":1}"#)) == nil)
    #expect(storableObject(try OrderedJSON(parsing: #"[1]"#)) == nil)
  }
}
