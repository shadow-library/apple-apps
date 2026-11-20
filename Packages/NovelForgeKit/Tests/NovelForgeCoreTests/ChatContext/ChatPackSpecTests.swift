import Foundation
import ShadowText
import Testing

@testable import NovelForgeCore

struct ChatPackSpecTests {
  private static func idea(_ statement: String) -> ChatPackLedgerEntry {
    ChatPackLedgerEntry(
      kind: .rejected, topic: "idea.x", statement: statement, why: nil, rejectedAlternatives: [], writerLine: nil, decidedBy: .author, ideaId: "idea-1", rejectionScope: .never)
  }

  private static func chapter(_ number: Int, isolated: Bool = false) -> ChatPackChapter {
    ChatPackChapter(number: number, title: "T\(number)", summary: "S\(number)", isolated: isolated)
  }

  private static func inputs(chapters: [ChatPackChapter] = [], latestChapter: ChatPackEndingRow? = nil, latestDraft: ChatPackEndingDraft? = nil) -> ChatPackInputs {
    ChatPackInputs(
      story: nil, progress: nil, ledger: [], authorNotes: nil, volumes: [], promises: [], entities: [], pages: [], facts: [], milestones: [], chapters: chapters, drafts: [],
      plannedChapters: [], briefs: [], latestChapter: latestChapter, latestDraft: latestDraft,
      pipeline: ChatPackPipeline(storyCurrentChapter: 0, drafts: [], staleBriefChapters: [], pendingProposals: 0, awaiting: .none),
      changes: ChatPackChanges(volumes: [], briefs: [], docs: []))
  }

  @Test func shouldDropTheHalfPairWhereTheReferenceSlicesThroughOneInATurnedDownLine() {
    let statement = String(repeating: "x", count: 158) + "😀" + String(repeating: "y", count: 40)
    let rendered = ChatPack.renderNotebook([Self.idea(statement)])
    #expect(rendered.jsIncludes(String(repeating: "x", count: 158) + "… (never)"))
    #expect(!rendered.contains("😀"))
  }

  @Test func shouldKeepAWholePairThatEndsAtTheCut() {
    let statement = String(repeating: "x", count: 157) + "😀" + String(repeating: "y", count: 40)
    #expect(ChatPack.renderNotebook([Self.idea(statement)]).jsIncludes(String(repeating: "x", count: 157) + "😀… (never)"))
  }

  @Test func shouldPersistAnUnresolvedOmissionApartFromABudgetOne() throws {
    let omissions = [ChatPackOmission(key: "inventory", reason: .unresolved), ChatPackOmission(BudgetOmission(key: "promises", reason: .budget, tokens: 40))]
    let encoded = try JSONEncoder().encode(omissions)
    #expect(try JSONDecoder().decode([ChatPackOmission].self, from: encoded) == omissions)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(text.contains(#""reason":"unresolved""#) && text.contains(#""reason":"budget""#))
    #expect(omissions[0].tokens == nil && omissions[1].tokens == 40)
  }

  @Test func shouldHeadAnUnknownKeyByItsUppercasedWords() {
    #expect(renderSection("two_words_here", "x") == "## TWO WORDS HERE\n\nx")
  }

  @Test func shouldReadAWalledOffEndingWithoutABridgeAndLeaveOutTheContinuationState() throws {
    let row = ChatPackEndingRow(content: "secret prose", summary: "a summary", isolated: true)
    let ending = try #require(try ChatPack.previousEnding(chapter: 3, row: row, draft: nil))
    expectSame(ending.rendered, "## PREVIOUS CHAPTER ENDING\n\n\(ChatPack.noApprovedBridge)", "isolated row")
    #expect(ending.tier == .canonical && ending.sourceRefs == ["chapter:3"])
    let draft = ChatPackEndingDraft(body: "secret prose", summary: nil, isolated: true, staleReason: "")
    let drafted = try #require(try ChatPack.previousEnding(chapter: 4, row: nil, draft: draft))
    expectSame(drafted.rendered, "## PREVIOUS CHAPTER ENDING\n\n[DRAFT — not yet canon]\n\(ChatPack.staleLabel)\n\(ChatPack.noApprovedBridge)", "isolated draft")
    #expect(drafted.tier == .working)
  }

  @Test func shouldNotReadAnEndingFromNothingOrAnEmptyDraft() throws {
    #expect(try ChatPack.previousEnding(chapter: 0, row: nil, draft: nil) == nil)
    #expect(try ChatPack.previousEnding(chapter: 2, row: nil, draft: ChatPackEndingDraft(body: "", summary: nil, isolated: false, staleReason: nil)) == nil)
  }

  @Test func shouldNeverEmitASectionTheVaultCannotFill() throws {
    let allowed: Set<String> = [
      "story", "notebook", "author_notes", "volume_plan", "promises", "inventory", "chapter_index", "handoff", "prev_ending", "pipeline_status", "changed_since", "progress",
    ]
    for pack in try ChatContextFixture.shared.get().packs {
      let sections = try ChatPack.sections(pack.inputs)
      #expect(Set((sections.stable + sections.volatile).map(\.key)).isSubset(of: allowed))
    }
    let empty = try ChatPack.sections(Self.inputs())
    #expect(empty.stable.map(\.key) == ["notebook"])
    #expect(empty.volatile.map(\.key) == ["handoff", "pipeline_status"])
  }

  @Test func shouldReadAnIsolatedLatestChapterAsWalledOffThroughoutThePack() throws {
    let row = ChatPackEndingRow(content: "secret prose", summary: "secret summary", isolated: true)
    let sections = try ChatPack.sections(Self.inputs(chapters: [Self.chapter(1), Self.chapter(2, isolated: true)], latestChapter: row))
    let text = joinSections(sections.stable + sections.volatile)
    #expect(!text.contains("secret") && !text.contains("T2") && !text.contains("S2"))
    #expect(text.contains(ChatPack.noBridgeSummary) || text.contains(ChatPack.noApprovedBridge))
    #expect(text.contains("2 — Chapter 2 [final, unrestricted]"))
  }

  @Test func shouldTakeAProgressLineFromAChecklistItem() {
    let item = ProgressItem<Int>(key: .premise, label: "the premise", why: "x", status: .answered, overrideEntryId: nil)
    #expect(ChatPackProgressLine(item) == ChatPackProgressLine(status: .answered, label: "the premise"))
    let dismissed = ProgressItem<Int>(key: .ending, label: "the ending", why: "x", status: .dismissed, overrideEntryId: nil)
    #expect(ChatPack.renderProgress([ChatPackProgressLine(dismissed)]) == nil)
  }
}

@Suite("Chat pack facts from the reader disclosure", TestTimeLimit.standard)
struct ChatPackDisclosureTests {
  @Test func shouldShowSinceWhichChapterTheReaderKnowsAndLeaveTheRestSecret() async throws {
    let store = try await ReadWorld.seeded()
    try await ReadWorld.write(store) { transaction in try PlanWorldWrites.secret(novel: readNovel, "tide", revealChapter: 2, in: &transaction) }
    let disclosure = try await store.load(ReaderDisclosure.self, readNovel)
    let facts = ["heir", "tide"].map { ChatPackFact(factKey: $0, in: disclosure) }
    #expect(facts.map(\.disclosedInChapter) == [1, nil])
    let inventory = ChatPack.renderInventory(entities: [], pages: [], facts: facts, milestones: [])
    #expect(inventory.jsIncludes("heir (reader knows since ch 1)\ntide (secret)"))
  }

  @Test func shouldKeepEverySecretSecretWhileTheDisclosureIsUnavailable() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    try await ReadWorld.insertFault(FinalChapterEntry.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    let disclosure = try await store.load(ReaderDisclosure.self, readNovel)
    #expect(disclosure.chapter(of: "heir").isUnavailable)
    let fact = ChatPackFact(factKey: "heir", in: disclosure)
    #expect(fact.disclosedInChapter == nil)
    #expect(ChatPack.renderInventory(entities: [], pages: [], facts: [fact], milestones: []).jsIncludes("heir (secret)"))
  }
}
