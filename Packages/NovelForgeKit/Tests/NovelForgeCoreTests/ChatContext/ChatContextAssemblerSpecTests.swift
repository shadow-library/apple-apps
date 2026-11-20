import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

struct ChatContextAssemblerSpecTests {
  private static func spec(_ name: String) throws -> ChatAssemblyFixture.Spec {
    try #require(try ChatAssemblyFixture.shared.get().scenarios.first { $0.spec.name == name }?.spec)
  }

  private static func pack(_ built: ChatAssemblyWorld.Built, since: HLCTimestamp? = nil) async throws -> (ChatContextInputs, ChatContextPack) {
    try await pack(built.store, since: since)
  }

  private static func pack(_ store: VaultStore, since: HLCTimestamp? = nil) async throws -> (ChatContextInputs, ChatContextPack) {
    let inputs = try await store.read { transaction in try ChatContextLoader.load(novel: ChatAssemblyWorld.novel, since: since, in: transaction) }
    return (inputs, ChatContextAssembler.assemble(inputs, promptTokens: 3000, requestTokens: 400))
  }

  private static func unresolved(_ pack: ChatContextPack) -> [String] {
    pack.omitted.filter { $0.reason == .unresolved }.map(\.key)
  }

  @Test func shouldHoldTheStableSegmentStillWhateverTheRequestCarries() async throws {
    let inputs = try await ChatAssemblyWorld.inputs(try await ChatAssemblyWorld.build(try Self.spec("budget pressure")))
    let light = ChatContextAssembler.assemble(inputs, promptTokens: 3000, requestTokens: 0)
    let heavy = ChatContextAssembler.assemble(inputs, promptTokens: 3000, requestTokens: 20_000)
    #expect(light.renderedStable == heavy.renderedStable)
    let stable = heavy.sections.filter { $0.segment == .stable }.reduce(0) { $0 + $1.tokens }
    #expect(stable > ChatPack.packFloor - ChatPack.packMargin)
    #expect(heavy.budgetTokens == stable)
  }

  @Test func shouldDateTheSessionFromItsOpeningNotItsLatestEdit() async throws {
    let built = try await ChatAssemblyWorld.build(try Self.spec("pending proposals and changes"))
    var edit = ChatSessionEdit()
    try edit.rename("Renamed later")
    let rename = edit
    try await ReadWorld.write(built.store) { transaction in _ = try ChatSessionRecord.edit(id: built.session, rename, in: &transaction) }
    let opened = try await built.store.read { transaction in try ChatContextLoader.sessionOpened(built.session, in: transaction) }
    #expect(opened == built.since)
  }

  @Test func shouldLeaveOutTheInventoryWhenWhatTheReaderKnowsCannotBeRead() async throws {
    let built = try await ChatAssemblyWorld.build(try Self.spec("isolated latest chapter"), allowingFaults: true)
    try await ReadWorld.insertFault(ReaderDisclosureEntry.databaseTableName, key: ProjectionFaults.wholeDerivation, in: built.store)
    let (inputs, pack) = try await Self.pack(built)
    #expect(inputs.unresolved == [.secrets])
    #expect(Self.unresolved(pack) == ["inventory"])
    #expect(!pack.sections.contains { $0.key == "inventory" })
  }

  @Test func shouldKeepTheReadableNotebookEntriesAndReportTheRest() async throws {
    let built = try await ChatAssemblyWorld.build(try Self.spec("no story"))
    try await ReadWorld.write(built.store) { transaction in
      _ = try NotebookEntryRecord(novel: ChatAssemblyWorld.novel, entryKind: StoredEnum(rawValue: "future"), topic: "later.kind", statement: "From a newer version.")
        .append(in: &transaction)
    }
    let (inputs, pack) = try await Self.pack(built)
    #expect(inputs.unresolved.isEmpty && inputs.incomplete == [.notebook])
    #expect(inputs.pack.ledger.map(\.topic) == ["voice.tone", "later"])
    #expect(Self.unresolved(pack).isEmpty && pack.partial.map(\.key) == ["notebook"])
    let notebook = try #require(pack.sections.first { $0.key == "notebook" })
    #expect(notebook.rendered.contains("voice.tone") && !notebook.rendered.contains(ChatContextAssembler.unreadableNotebook))
    #expect(notebook.rendered.hasSuffix("\n\n\(ChatContextAssembler.incompleteNotebook)") && !notebook.truncated)
  }

  @Test func shouldDropOnlyTheRejectionsWhoseScopeLapsed() async throws {
    let built = try await ChatAssemblyWorld.build(try Self.spec("notebook with lapsed rejections"))
    let inputs = try await ChatAssemblyWorld.inputs(built)
    #expect(inputs.pack.ledger.compactMap(\.ideaId) == ["never-idea", "now-idea", "kept-idea"])
    #expect(inputs.pack.ledger.contains { $0.topic == "plain" && $0.kind == .rejected })
  }

  @Test func shouldKeepEveryRejectionWhenTheVolumesCannotBeRead() async throws {
    let built = try await ChatAssemblyWorld.build(try Self.spec("notebook with lapsed rejections"), allowingFaults: true)
    try await ReadWorld.insertFault(VolumeStateEntry.databaseTableName, key: ProjectionFaults.wholeDerivation, in: built.store)
    let (inputs, pack) = try await Self.pack(built)
    #expect(inputs.pack.ledger.compactMap(\.ideaId) == ["never-idea", "now-idea", "then-idea", "kept-idea", "moved-idea"])
    #expect(inputs.pack.volumes.isEmpty)
    #expect(Self.unresolved(pack) == ["volume_plan", "promises", "changed_since"])
    #expect(!pack.sections.contains { $0.key == "volume_plan" })
  }

  @Test func shouldKeepARejectionWhoseAnchoredRecordCannotBeRead() async throws {
    let built = try await ChatAssemblyWorld.build(try Self.spec("notebook with lapsed rejections"))
    try await ReadWorld.write(built.store) { transaction in
      _ = try transaction.set(EntityRecord(novel: ChatAssemblyWorld.novel, entity: "heir", type: .known(.character), name: "").ref, ["name": .int(1)])
    }
    let inputs = try await ChatAssemblyWorld.inputs(built)
    #expect(inputs.pack.ledger.compactMap(\.ideaId) == ["never-idea", "now-idea", "kept-idea", "moved-idea"])
    #expect(inputs.pack.entities.map(\.entityKey) == ["mara"])
  }

  @Test func shouldWallOffAnUnreadableLatestChapterAndLeaveOutItsEnding() async throws {
    let built = try await ChatAssemblyWorld.build(try Self.spec("isolated latest chapter"))
    try await ReadWorld.write(built.store) { transaction in
      let key = try NovelForgeKey.finalChapterKey(novel: ChatAssemblyWorld.novel, chapter: 4)
      _ = try transaction.set(key.ref, [CommonField.naturalKey.rawValue: key.stored, FinalChapterField.canon.rawValue: .object(["body": .int(1)])])
    }
    let (inputs, pack) = try await Self.pack(built)
    #expect(inputs.pack.chapters.last == ChatPackChapter(number: 4, title: nil, summary: nil, isolated: true))
    #expect(inputs.pack.latestChapter == nil && inputs.unresolved == [.latestEnding])
    #expect(Self.unresolved(pack) == ["prev_ending"])
    #expect(!pack.sections.contains { $0.key == "prev_ending" })
    #expect(pack.renderedVolatile.contains("Next chapter: 5"))
  }

  @Test func shouldStandInForAnUnreadableNotebookSoTheStableContextStaysNonEmpty() async throws {
    let built = try await ChatAssemblyWorld.build(try Self.spec("no story"), allowingFaults: true)
    try await ReadWorld.insertFault(NotebookEntryStateRow.databaseTableName, key: ProjectionFaults.wholeDerivation, in: built.store)
    let (_, pack) = try await Self.pack(built)
    let notebook = try #require(pack.sections.first { $0.key == "notebook" })
    #expect(notebook.segment == .stable && notebook.required)
    #expect(notebook.rendered.hasSuffix(ChatContextAssembler.unreadableNotebook))
    #expect(!pack.renderedStable.isEmpty)
    #expect(Self.unresolved(pack).isEmpty && pack.partial.map(\.key) == ["notebook"])
  }

  @Test func shouldLeaveOutWhatTheChapterReadsFeedWhenTheyFault() async throws {
    let built = try await ChatAssemblyWorld.build(try Self.spec("pending proposals and changes"), allowingFaults: true)
    try await ReadWorld.insertFault(ChapterLifecycleEntry.databaseTableName, key: ProjectionFaults.wholeDerivation, in: built.store)
    let (_, pack) = try await Self.pack(built, since: built.since)
    #expect(Self.unresolved(pack) == ["promises", "chapter_index", "prev_ending", "pipeline_status", "changed_since", "progress"])
    #expect(pack.partial.map(\.key) == ["handoff"])
    let handoff = try #require(pack.sections.first { $0.key == "handoff" })
    #expect(handoff.rendered.hasSuffix(ChatContextAssembler.unreadableHandoff) && handoff.required)
    #expect(pack.sections.map(\.key) == ["story", "notebook", "author_notes", "volume_plan", "inventory", "handoff"])
  }

  @Test func shouldLeaveOutEverySectionAFaultedPlanRevealReaches() async throws {
    let built = try await ChatAssemblyWorld.build(try Self.spec("isolated latest chapter"), allowingFaults: true)
    try await ReadWorld.insertFault(PlanRevealEntry.databaseTableName, key: String(reflecting: ChatAssemblyWorld.novel), in: built.store)
    let (_, pack) = try await Self.pack(built)
    #expect(Self.unresolved(pack) == ["promises", "chapter_index", "prev_ending", "pipeline_status", "changed_since", "progress"])
    #expect(pack.partial.map(\.key) == ["handoff"])
    #expect(pack.sections.map(\.key) == ["story", "notebook", "inventory", "handoff"])
  }

  @Test func shouldIgnoreAFaultInAnotherNovel() async throws {
    let built = try await ChatAssemblyWorld.build(try Self.spec("isolated latest chapter"), allowingFaults: true)
    try await ReadWorld.insertFault(ChapterLifecycleEntry.databaseTableName, key: String(reflecting: SchemaFixture.otherNovel), in: built.store)
    let (inputs, pack) = try await Self.pack(built)
    #expect(inputs.unresolved.isEmpty && Self.unresolved(pack).isEmpty && pack.partial.isEmpty)
  }

  @Test func shouldReadAnEmptyVaultAsNothingWrittenWithAStableNotebook() async throws {
    let store = try ReadWorld.store()
    let (inputs, pack) = try await Self.pack(store)
    #expect(inputs.unresolved.isEmpty && inputs.pack.story == nil && inputs.pack.progress == nil)
    #expect(pack.sections.map(\.key) == ["notebook", "handoff", "pipeline_status"])
    #expect(pack.renderedStable == "## THE NOTEBOOK (THE AUTHOR'S DECISIONS)\n\nNothing has been decided yet.")
    #expect(pack.renderedVolatile.contains("Nothing is written yet.\nNext chapter: 1 — no plan yet."))
  }

  @Test func shouldListChangesOnlyAfterTheSessionOpenedAndOnlyWhenAsked() async throws {
    let built = try await ChatAssemblyWorld.build(try Self.spec("pending proposals and changes"))
    let (asked, _) = try await Self.pack(built, since: built.since)
    #expect(asked.pack.changes.volumes.map(\.volumeKey) == ["v1"])
    #expect(asked.pack.changes.briefs.map { "\($0.chapter)@\($0.revision)" } == ["4@2"])
    #expect(asked.pack.changes.docs.map { "\($0.slug)@\($0.revision)" } == ["oaths@2"])
    let (unasked, pack) = try await Self.pack(built)
    #expect(unasked.pack.changes == ChatPackChanges(volumes: [], briefs: [], docs: []))
    #expect(!pack.sections.contains { $0.key == "changed_since" })
    let opened = try await built.store.read { transaction in try ChatContextLoader.sessionOpened(UUID(), in: transaction) }
    #expect(opened == nil)
  }

  @Test func shouldCountOnlyThisNovelsPendingProposals() async throws {
    let built = try await ChatAssemblyWorld.build(try Self.spec("pending proposals and changes"))
    #expect(try await ChatAssemblyWorld.inputs(built).pack.pipeline.pendingProposals == 2)
  }

  @Test func shouldCountAPendingProposalWhoseCardCannotBeRead() async throws {
    let built = try await ChatAssemblyWorld.build(try Self.spec("pending proposals and changes"))
    let card: JSONValue = ["novel": ChatAssemblyWorld.novel.json, "change_set": "later"]
    try await ReadWorld.write(built.store) { transaction in _ = try transaction.set(NovelForgeKey.proposal(UUID()), ["card": card, "decision": "pending"]) }
    let (inputs, pack) = try await Self.pack(built)
    #expect(inputs.pack.pipeline.pendingProposals == 3 && inputs.incomplete.isEmpty && pack.partial.isEmpty)
  }

  @Test func shouldKeepThePipelineStatusMarkedPartialWhenProposalsAreFaulted() async throws {
    for key in [ProjectionFaults.key(NovelForgeKey.proposal(UUID())), ProjectionFaults.wholeDerivation] {
      let built = try await ChatAssemblyWorld.build(try Self.spec("pending proposals and changes"), allowingFaults: true)
      try await ReadWorld.insertFault(ProposalState.databaseTableName, key: key, in: built.store)
      let (inputs, pack) = try await Self.pack(built)
      #expect(inputs.unresolved.isEmpty && inputs.incomplete == [.proposals], "\(key)")
      #expect(pack.partial.map(\.key) == ["pipeline_status"] && pack.sections.contains { $0.key == "pipeline_status" }, "\(key)")
      #expect(inputs.pack.pipeline.pendingProposals == (key == ProjectionFaults.wholeDerivation ? 0 : 2), "\(key)")
    }
  }

  @Test func shouldFlagAChangedOrLeftOutSectionAndSayWhatIsGone() throws {
    let section = { (key: String, text: String) in ChatPack.makeSection(key, text, tier: .working) }
    let before = ChatContextPack(
      sections: [section("handoff", "One."), section("progress", "Two."), section("changed_since", "Three.")], omitted: [], partial: [], budgetTokens: 10, usedTokens: 3,
      renderedStable: "", renderedVolatile: "")
    let after = ChatContextPack(
      sections: [section("handoff", "One, changed.")], omitted: [ChatPackOmission(key: "progress", reason: .budget, tokens: 9)], partial: [], budgetTokens: 10,
      usedTokens: 1,
      renderedStable: "", renderedVolatile: "")
    let update = ChatContextExchange.contextUpdate(after, holding: ChatContextExchange.contextUpdate(before, holding: nil).sections)
    #expect(
      update.text
        == "\(ChatContextExchange.changed)\n\n## WHERE THE STORY STANDS\n\nOne, changed.\n\n---\n\n## PROGRESS\n\n\(ChatContextExchange.leftOut)\n\n---\n\n"
        + "## CHANGED SINCE THIS CONVERSATION STARTED\n\n\(ChatContextExchange.gone)")
    #expect(update.sections.entries.map(\.key) == ["handoff"])
    let unreadable = ChatContextPack(
      sections: [], omitted: [ChatPackOmission(key: "handoff", reason: .unresolved)], partial: [], budgetTokens: 10, usedTokens: 0, renderedStable: "", renderedVolatile: "")
    #expect(
      ChatContextExchange.contextUpdate(unreadable, holding: update.sections).text
        == "\(ChatContextExchange.changed)\n\n## WHERE THE STORY STANDS\n\n\(ChatContextExchange.unreadable)")
    #expect(ChatContextExchange.contextUpdate(after, holding: nil).text == "nothing")
  }
}

struct ChatContextExchangeTests {
  private static let session = UUID()

  private static func exchange(_ segment: String, opening: ChatSegmentOpening? = nil, message: String = "Where the story stands now: 😀 e\u{301}") -> ChatExchange {
    let held = [(key: "notebook", section: ChatHeldSection(digest: "d1", heading: "## N")), (key: "handoff", section: ChatHeldSection(digest: "d2", heading: "## H"))]
    return ChatExchange(
      segment: segment, opening: opening, sections: ChatHeldSections(held), messages: [PromptMessage(.user, message), PromptMessage(.assistant, "{\"reply\":\"ok\"}")])
  }

  private static func row(_ role: ChatRole, turn: UUID?, exchange: ChatExchange? = nil, text: String) -> ChatExchangeRow<String> {
    ChatExchangeRow(role: role, turn: turn, exchange: exchange, message: text)
  }

  private static let opening = ChatSegmentOpening(through: "summary-1", playbook: "p", stableContext: "## STORY")

  @Test func shouldKeepEachReplysExchangeOnThisDeviceOnly() async throws {
    let store = try ReadWorld.store()
    let first = UUID()
    let second = UUID()
    let elsewhere = UUID()
    #expect(try await store.read { transaction in try ChatContextExchangeLog.load(session: Self.session, in: transaction.database) }.isEmpty)
    try await store.write { transaction in
      try ChatContextExchangeLog.record(Self.exchange("s1", opening: Self.opening), reply: first, session: Self.session, in: transaction.database)
      try ChatContextExchangeLog.record(Self.exchange("s1", message: "first"), reply: second, session: Self.session, in: transaction.database)
      try ChatContextExchangeLog.record(Self.exchange("s1", message: "second"), reply: second, session: Self.session, in: transaction.database)
      try ChatContextExchangeLog.record(Self.exchange("s9"), reply: UUID(), session: elsewhere, in: transaction.database)
    }
    let loaded = try await store.read { transaction in try ChatContextExchangeLog.load(session: Self.session, in: transaction.database) }
    #expect(loaded == [first: Self.exchange("s1", opening: Self.opening), second: Self.exchange("s1", message: "second")])
    #expect(loaded[first]?.sections.entries.map(\.key) == ["notebook", "handoff"])
    try await store.write { transaction in try ChatContextExchangeLog.forget(session: Self.session, in: transaction.database) }
    #expect(try await store.read { transaction in try ChatContextExchangeLog.load(session: Self.session, in: transaction.database) }.isEmpty)
    #expect(try await store.read { transaction in try ChatContextExchangeLog.load(session: elsewhere, in: transaction.database) }.count == 1)
  }

  @Test func shouldSendThePlainHistoryWhenAnyOfTheSessionsExchangesCannotBeRead() async throws {
    let store = try ReadWorld.store()
    try await store.write { transaction in
      try ChatContextExchangeLog.record(Self.exchange("s1", opening: Self.opening), reply: UUID(), session: Self.session, in: transaction.database)
      try ChatContextExchangeLog.record(Self.exchange("s1"), reply: UUID(), session: Self.session, in: transaction.database)
      try transaction.database.execute(
        sql: "INSERT INTO \(ChatContextExchangeLog.table) (session, reply, exchange) VALUES (?, ?, ?)", arguments: [Self.session, UUID(), Data("{}".utf8)])
    }
    #expect(try await store.read { transaction in try ChatContextExchangeLog.load(session: Self.session, in: transaction.database) }.isEmpty)
  }

  @Test func shouldHoldTheSegmentOnlyWhileTheWatermarkAndPlaybookStand() {
    let turn = UUID()
    let rows = [Self.row(.user, turn: turn, text: "hi"), Self.row(.assistant, turn: turn, exchange: Self.exchange("s1", opening: Self.opening), text: "ok")]
    let held = ChatContextExchange.heldSegment(rows, through: "summary-1", playbook: "p")
    #expect(held?.id == "s1" && held?.stableContext == "## STORY" && held?.sections == Self.exchange("s1").sections)
    #expect(ChatContextExchange.heldSegment(rows, through: "summary-2", playbook: "p") == nil)
    #expect(ChatContextExchange.heldSegment(rows, through: "summary-1", playbook: "q") == nil)
    let elsewhere = rows + [Self.row(.user, turn: UUID(), text: "again"), Self.row(.assistant, turn: nil, text: "answered on another device")]
    #expect(ChatContextExchange.heldSegment(elsewhere, through: "summary-1", playbook: "p") == nil)
    let unopened = [Self.row(.assistant, turn: turn, exchange: Self.exchange("s2"), text: "ok")]
    #expect(ChatContextExchange.heldSegment(unopened, through: "summary-1", playbook: "p") == nil)
  }

  @Test func shouldReplayTheSegmentAsSentAndRenderTheRestPlainly() {
    let first = UUID()
    let second = UUID()
    let rows = [
      Self.row(.user, turn: first, text: "u1"), Self.row(.assistant, turn: first, exchange: Self.exchange("s1", opening: Self.opening, message: "sent 1"), text: "r1"),
      Self.row(.user, turn: second, text: "u2"), Self.row(.assistant, turn: second, exchange: Self.exchange("s0", message: "old"), text: "r2"),
    ]
    let replayed = ChatContextExchange.replayWindow(rows, segment: "s1") { [PromptMessage($0.role == .user ? .user : .assistant, $0.message)] }
    #expect(
      replayed == [
        PromptMessage(.user, "sent 1"), PromptMessage(.assistant, "{\"reply\":\"ok\"}"), PromptMessage(.assistant, "r1"), PromptMessage(.user, "u2"),
        PromptMessage(.assistant, "r2"),
      ])
  }

  @Test func shouldDigestThePlaybookAndHeadSectionsByTheirFirstLine() {
    #expect(ChatContextExchange.playbookDigest("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    let held = ChatContextExchange.held(ChatPack.makeSection("handoff", "Line one\nline two", tier: .working))
    #expect(held.heading == "## WHERE THE STORY STANDS" && held.digest == sha256Hex("## WHERE THE STORY STANDS\n\nLine one\nline two"))
  }
}
