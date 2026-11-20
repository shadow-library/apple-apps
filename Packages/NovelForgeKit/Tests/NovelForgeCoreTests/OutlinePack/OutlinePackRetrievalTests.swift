import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import NovelForgeCore

@Suite("Outline pack retrieval", TestTimeLimit.standard)
struct OutlinePackRetrievalTests {
  private static let novel = OutlinePackWorld.novel
  private static let request = OutlineRequest(chapter: 3, volume: .key("v1"))

  private static func world(objective: String = "Lighthouse\nBells ring in the last chapter.") async throws -> VaultStore {
    let store = try ReadWorld.store()
    try await ReadWorld.write(store) { transaction in
      _ = try VolumeRecord(novel: novel, volume: "v1", ordinal: 1, title: "One", objective: objective, goalMet: false).create(in: &transaction)
      _ = try EntityRecord(novel: novel, entity: "keeper", type: .known(.character), name: "Keeper", notes: "Tends the lighthouse.").create(in: &transaction)
      _ = try FinalChapterRecord(novel: novel, chapter: 1, canon: Canon(body: "The lighthouse keeper climbed the stairs.")).finalize(in: &transaction)
      _ = try FinalChapterRecord(novel: novel, chapter: 2, canon: Canon(body: "Bells over the harbour.")).finalize(in: &transaction)
    }
    return store
  }

  private static func section(_ key: String, of pack: OutlinePack) -> ChatPackSection? {
    pack.sections.first { $0.key == key }
  }

  @Test func shouldRecallProseAndLoreForTheFirstLineOfTheVolumeGoalFromAnIndexCaughtUpFirst() async throws {
    let store = try await Self.world()
    let retrieval = OutlineRetrieval.index(NovelRetrieval(store: store))
    let pack = try await store.outlinePack(novel: Self.novel, request: Self.request, retrieval: retrieval)
    let prose = try #require(Self.section("prose_retrieved", of: pack))
    #expect(prose.rendered == "## PROSE REFERENCES\n\n1. [Ch 1] The lighthouse keeper climbed the stairs.")
    #expect(!prose.required && prose.tier == .canonical && prose.segment == .volatile && prose.sourceRefs.isEmpty)
    #expect(Self.section("lore_retrieved", of: pack)?.rendered == "## LORE REFERENCES\n\n1. [character:keeper] Keeper\nTends the lighthouse.")
    #expect(pack.sections.suffix(3).map(\.key) == ["catalog", "prose_retrieved", "lore_retrieved"])

    let ref = try FinalChapterRecord.ref(novel: Self.novel, chapter: 1)
    try await ReadWorld.write(store) { transaction in
      _ = try FinalChapterRecord.amend(ref, FinalChapterText(body: "The lighthouse went dark at dusk."), in: &transaction)
    }
    let amended = try await store.outlinePack(novel: Self.novel, request: Self.request, retrieval: retrieval)
    #expect(Self.section("prose_retrieved", of: amended)?.rendered == "## PROSE REFERENCES\n\n1. [Ch 1] The lighthouse went dark at dusk.")
  }

  @Test func shouldLeaveTheRetrievedSectionsOutWithoutARetrievalOrAQuery() async throws {
    let store = try await Self.world()
    let without = try await store.outlinePack(novel: Self.novel, request: Self.request)
    #expect(!without.sections.contains { $0.key.hasSuffix("_retrieved") })

    let blank = try await Self.world(objective: "\nLighthouse")
    let searched = SearchCount()
    let pack = try await blank.outlinePack(novel: Self.novel, request: Self.request, retrieval: searched.retrieval)
    #expect(searched.count == 0)
    #expect(!pack.sections.contains { $0.key.hasSuffix("_retrieved") })
  }

  // isolated-chapters.ts: the planner reads an isolated chapter only through its bridge, never as retrieved prose, even when it reads isolated chapters raw
  @Test func shouldNeverRecallTheProseOfAChapterIsolatedNow() async throws {
    let store = try await Self.world()
    try await ReadWorld.write(store) { transaction in
      _ = try FinalChapterRecord(novel: Self.novel, chapter: 3, canon: Canon(body: "The lighthouse hid the ZEBRAQUILL.", isolated: true)).finalize(in: &transaction)
      _ = try FinalChapterRecord(novel: Self.novel, chapter: 4, canon: Canon(body: "Fog.")).finalize(in: &transaction)
    }
    let retrieval = OutlineRetrieval.index(NovelRetrieval(store: store))
    for raw in [false, true] {
      let pack = try await store.outlinePack(novel: Self.novel, request: OutlineRequest(chapter: 5, volume: .key("v1"), readsIsolatedRaw: raw), retrieval: retrieval)
      #expect(Self.section("prose_retrieved", of: pack)?.rendered == "## PROSE REFERENCES\n\n1. [Ch 1] The lighthouse keeper climbed the stairs.", "raw \(raw)")
      #expect(!pack.rendered.contains("ZEBRAQUILL"), "raw \(raw)")
    }
  }

  @Test func shouldScreenRetrievedTextForTheHardLineWhenThePlannerReadsIsolatedChaptersRaw() async throws {
    let store = try await Self.world()
    let hit = RetrievalHit(text: "a child, orgasm", score: 1, origin: .lore(kind: "character", refKey: "keeper"))
    let retrieval = OutlineRetrieval { _, _ in RetrievalResults(prose: [], lore: [hit]) }
    let standard = try await store.outlinePack(novel: Self.novel, request: Self.request, retrieval: retrieval)
    #expect(Self.section("lore_retrieved", of: standard) != nil)
    do {
      _ = try await store.outlinePack(novel: Self.novel, request: OutlineRequest(chapter: 3, volume: .key("v1"), readsIsolatedRaw: true), retrieval: retrieval)
      Issue.record("retrieved text reached the permissive pack unscreened")
    } catch {
      guard case .hardLine = error else {
        Issue.record("\(error)")
        return
      }
    }
  }
}

private final class SearchCount: Sendable {
  private let calls = Mutex(0)

  var count: Int { calls.withLock(\.self) }

  var retrieval: OutlineRetrieval {
    OutlineRetrieval { [self] _, _ in
      calls.withLock { $0 += 1 }
      return RetrievalResults(prose: [], lore: [])
    }
  }
}
