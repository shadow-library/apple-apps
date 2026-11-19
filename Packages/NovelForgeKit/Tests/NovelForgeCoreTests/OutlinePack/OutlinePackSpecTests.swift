import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

struct OutlinePackSpecTests {
  private static let mark = "ZEBRAQUILL"

  private static func spec(_ name: String) throws -> OutlinePackFixture.Spec {
    try #require(try OutlinePackFixture.shared.get().scenarios.first { $0.spec.name == name }).spec
  }

  private static func planContext(_ name: String) async throws -> ChapterPlanContext {
    let spec = try spec(name)
    let store = try await OutlinePackWorld.build(spec)
    return try await store.chapterPlanContext(novel: OutlinePackWorld.novel, chapter: spec.chapter, budgetTokens: spec.budgetTokens ?? OutlinePack.budget)
  }

  private static func pack(_ name: String) async throws -> OutlinePack {
    let spec = try spec(name)
    return try await OutlinePackWorld.build(spec).outlinePack(novel: OutlinePackWorld.novel, request: spec.request)
  }

  @Test func shouldTrimTheCatalogUnderBudgetPressureAndKeepTheRevealSchedule() async throws {
    let context = try await Self.planContext("many threads under budget pressure")
    #expect(context.catalog.contains("omitted)"))
    #expect(context.catalog.contains("REVEAL SCHEDULE (binding for chapters 25–25):"))
  }

  @Test func shouldLetTheEntityBudgetBindWhenNothingTrimsTheCatalog() async throws {
    let pack = try await Self.pack("entity budget binds with no catalog ceiling")
    #expect(pack.rendered.contains("(+10 minor entities omitted)"))
    #expect(!pack.rendered.contains("earlier chapters omitted"))
  }

  @Test func shouldTrimChaptersFirstFromTheOldestThenMysteries() async throws {
    let spec = "mid-size budget trims chapters then mysteries"
    let trimmed = try await Self.pack(spec).rendered
    #expect(trimmed.contains("(+51 earlier chapters omitted)"))
    #expect(trimmed.contains("less recently advanced mysteries omitted)"))
    #expect(!trimmed.contains("threads omitted)"))
    let partway = try await Self.pack("a smaller trim stops partway through the chapters").rendered
    #expect(partway.contains("(+45 earlier chapters omitted)"))
    #expect(partway.contains("\n51 — "))
    #expect(!partway.contains("\n6 — "))
  }

  @Test func shouldWallOffAnIsolatedChapterInTheRecentSummaries() async throws {
    let pack = try await Self.pack("mid volume").rendered
    #expect(pack.contains("Ch 5: \(ChatPack.noBridgeSummary)"))
  }

  @Test func shouldShowNothingOfAnIsolatedFinalChapterOrDraftItFollows() async throws {
    for name in ["after an isolated final chapter", "after an isolated draft"] {
      let context = try await Self.planContext(name)
      #expect(!context.catalog.contains(Self.mark), "\(name)")
      #expect(context.catalog.contains(ChatPack.noApprovedBridge), "\(name)")
      #expect(!context.pack.rendered.contains("CONTINUATION STATE"), "\(name)")
    }
  }

  @Test func shouldReadAnUnreadableFinalChapterAsWalledOff() async throws {
    let store = try ReadWorld.store()
    try await ReadWorld.write(store) { transaction in
      _ = try ChapterPlanRecord(novel: OutlinePackWorld.novel, chapter: 2, content: ChapterPlanContent(body: "Plan.")).create(in: &transaction)
      let key = try NovelForgeKey.finalChapterKey(novel: OutlinePackWorld.novel, chapter: 1)
      _ = try transaction.set(key.ref, [CommonField.naturalKey.rawValue: key.stored, FinalChapterField.canon.rawValue: .object(["body": .int(1)])])
    }
    let pack = try await store.outlinePack(novel: OutlinePackWorld.novel, request: OutlineRequest(chapter: 2))
    #expect(pack.rendered.contains(ChatPack.noApprovedBridge))
    #expect(pack.rendered.contains("Ch 1: \(ChatPack.noBridgeSummary)"))
  }

  @Test func shouldMarkAFactRevealedOnlyWhenACharacterKnowsIt() async throws {
    let context = try await Self.planContext("mid volume")
    #expect(context.catalog.contains("tower: "))
    #expect(context.catalog.contains(" (revealed)\n") || context.catalog.contains(" (revealed)"))
    let lines = context.catalog.split(separator: "\n").filter { $0.hasPrefix("tower: ") || $0.hasPrefix("ledger: ") }
    #expect(lines.first { $0.hasPrefix("tower: ") }?.hasSuffix("(revealed)") == true)
    #expect(lines.first { $0.hasPrefix("ledger: ") }?.hasSuffix("(revealed)") == false)
  }

  @Test func shouldDueAPromiseWhoseMilestoneIsReachedThroughAFinalChapter() async throws {
    let context = try await Self.planContext("a reached milestone that is a mystery payoff")
    #expect(context.obligations.contains { $0.text.hasPrefix("A promise due now that its payoff milestone is reached") })
  }

  @Test func shouldRefuseAPlanWhenASecretsUnlockCannotBeRead() async throws {
    let store = try ReadWorld.store()
    try await ReadWorld.write(store) { transaction in
      _ = try SecretRecord(novel: OutlinePackWorld.novel, secret: "broken", text: "x", unlock: .object(["all": .array([.object(["nonsense": .bool(true)])])])).create(
        in: &transaction)
    }
    do {
      _ = try await store.chapterPlanContext(novel: OutlinePackWorld.novel, chapter: 1)
      Issue.record("an unreadable unlock was planned over")
    } catch {
      guard case .unreadable(let parts) = error else {
        Issue.record("\(error)")
        return
      }
      #expect(parts.contains { $0.contains("broken") })
    }
  }

  @Test func shouldRefuseAPlanWhenTheStoredPlanWorldIsMissingForANovelWithInputs() async throws {
    let store = try await OutlinePackWorld.build(try Self.spec("first chapter"))
    try await store.write { transaction in
      _ = try transaction.database.execute(sql: "DELETE FROM \(PlanWorldEntry.databaseTableName)")
    }
    do {
      _ = try await store.chapterPlanContext(novel: OutlinePackWorld.novel, chapter: 1)
      Issue.record("a missing plan world was planned over")
    } catch {
      guard case .unreadable(let parts) = error else {
        Issue.record("\(error)")
        return
      }
      #expect(parts.contains("plan world"))
    }
  }

  @Test func shouldScreenOnlyThePermissivePackForTheHardLine() async throws {
    let store = try ReadWorld.store()
    try await ReadWorld.write(store) { transaction in
      let canon = Canon(title: nil, body: "Body.", summary: "a child, orgasm", contract: ChapterContract())
      _ = try DraftRecord(novel: OutlinePackWorld.novel, chapter: 1, content: DraftContent(body: "Body.", summary: "a child, orgasm", source: .known(.generated))).create(
        in: &transaction)
      _ = try FinalChapterRecord(novel: OutlinePackWorld.novel, chapter: 1, canon: canon).finalize(in: &transaction)
    }
    _ = try await store.outlinePack(novel: OutlinePackWorld.novel, request: OutlineRequest(chapter: 2))
    do {
      _ = try await store.outlinePack(novel: OutlinePackWorld.novel, request: OutlineRequest(chapter: 2, readsIsolatedRaw: true))
      Issue.record("the permissive pack was not screened")
    } catch {
      guard case .hardLine = error else {
        Issue.record("\(error)")
        return
      }
    }
  }

  @Test func shouldScreenAMinorsNameInThePermissivePack() async throws {
    let store = try ReadWorld.store()
    try await ReadWorld.write(store) { transaction in
      _ = try EntityRecord(novel: OutlinePackWorld.novel, entity: "pip", type: .known(.character), name: "Pippinella", age: 9).create(in: &transaction)
      _ = try ThreadRecord(novel: OutlinePackWorld.novel, thread: "t", summary: "Pippinella, orgasm", status: ThreadProgress(state: .known(.open))).create(in: &transaction)
    }
    #expect(try await store.chapterPlanContext(novel: OutlinePackWorld.novel, chapter: 1).catalog.contains("Pippinella, orgasm"))
    do {
      _ = try await store.chapterPlanContext(novel: OutlinePackWorld.novel, chapter: 1, readsIsolatedRaw: true)
      Issue.record("a minor's name was not screened")
    } catch {
      guard case .hardLine = error else {
        Issue.record("\(error)")
        return
      }
    }
  }

  @Test func shouldRefuseWhileTheChapterLifecycleIsFaulted() async throws {
    let spec = try Self.spec("mid volume")
    let store = try await OutlinePackWorld.build(spec)
    try await ReadWorld.insertFault(ChapterLifecycleEntry.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    do {
      _ = try await store.chapterPlanContext(novel: OutlinePackWorld.novel, chapter: spec.chapter)
      Issue.record("a faulted chapter lifecycle was planned over")
    } catch {
      guard case .unreadable(let parts) = error else {
        Issue.record("\(error)")
        return
      }
      #expect(parts.contains("chapters"))
    }
  }

  @Test func shouldTrimAgainWhenTheOmissionNoteLeavesTheCatalogOverItsCeiling() {
    let chapters = (1...40).map { OutlineChapter(number: $0, title: "Chapter title \($0)", summary: nil, isolated: false) }
    let world = OutlineWorld(
      chapters: chapters, previous: nil, previousDraft: nil, volumes: [], entities: [], threads: [], mysteries: [], facts: [], documents: [], ledger: [],
      planWorld: PlanWorld(plans: [], milestones: [], volumeOrdinals: [:]), milestones: [], characters: [], slot: nil, previousEnding: nil, neighbours: [], minorNames: [])
    let whole = countTokens(world.catalog(OutlineCatalogOptions()))
    for ceiling in (whole - 120)..<whole {
      let catalog = world.catalog(OutlineCatalogOptions(maxTokens: ceiling))
      #expect(countTokens(catalog) <= ceiling, "ceiling \(ceiling)")
    }
  }

  @Test func shouldSortSlugsLikeTheLocaleCompareOfAsciiPages() {
    let documents = ["b-two", "b_two", "b2", "a", "B-one"].map { OutlineDocument(section: "lore", slug: $0, frontmatter: nil, body: "x") }
    #expect(OutlineDocument.ranked(documents).map(\.slug) == ["a", "b_two", "B-one", "b-two", "b2"])
  }

  @Test func shouldListLedgerBlocksAndLeaveOutTheBriefAndProgress() {
    func entry(_ kind: LedgerEntryKind, _ topic: String) -> ChatPackLedgerEntry {
      ChatPackLedgerEntry(kind: kind, topic: topic, statement: "S", why: nil, rejectedAlternatives: [], writerLine: nil, decidedBy: .author)
    }
    #expect(ChatPack.renderLedger([entry(.direction, "start.brief"), entry(.system, "progress.x")]) == "Nothing has been decided yet.")
    let section = ChatPack.ledgerSection([entry(.decision, "a.b"), entry(.backlog, "later"), entry(.direction, "start.brief")], segment: .volatile)
    #expect(section.sourceRefs == ["ledger:a.b", "ledger:later"])
    #expect(section.required)
  }
}
