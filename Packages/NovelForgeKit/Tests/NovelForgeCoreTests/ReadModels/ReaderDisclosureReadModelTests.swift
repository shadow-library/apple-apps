import Foundation
import GRDB
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Reader disclosure read model", TestTimeLimit.standard)
struct ReaderDisclosureReadModelTests {
  @Test func shouldTellWhenTheReaderLearnedEachSecret() async throws {
    let store = try await ReadWorld.seeded()
    try await ReadWorld.write(store) { transaction in
      try PlanWorldWrites.secret(novel: readNovel, "tide", revealChapter: 2, in: &transaction)
      try PlanWorldWrites.secret(novel: readOtherNovel, "heir", revealChapter: 1, in: &transaction)
    }
    let disclosure = try await store.load(ReaderDisclosure.self, readNovel)
    #expect(disclosure.entries.value?.map(\.secret) == ["heir"])
    #expect(disclosure.chapter(of: "heir") == .available(1))
    #expect(disclosure.chapter(of: "tide") == .available(nil))
    #expect(disclosure.secrets(disclosedIn: 1) == .available(["heir"]))
    #expect(disclosure.secrets(disclosedIn: 2) == .available([]))
    #expect(disclosure.isShown("heir", before: 1) == .available(false))
    #expect(disclosure.isShown("heir", before: 2) == .available(true))
    #expect(disclosure.isShown("tide", before: 9) == .available(false))
    #expect(disclosure.faults.isEmpty)
    #expect(try await store.load(StoryScreen.self, readNovel).disclosure == disclosure)
  }

  @Test func shouldBeUnavailableOnAFaultOfThisNovelOrOfTheFinalChaptersAndShowItOnTheStoryScreen() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    try await ReadWorld.insertFault(ReaderDisclosureEntry.databaseTableName, key: String(reflecting: readOtherNovel), in: store)
    #expect(try await store.load(ReaderDisclosure.self, readNovel).entries.value?.count == 1)
    try await ReadWorld.insertFault(FinalChapterEntry.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    let disclosure = try await store.load(ReaderDisclosure.self, readNovel)
    #expect(disclosure.chapter(of: "heir").isUnavailable)
    #expect(disclosure.faults.map(\.derivation) == [FinalChapterEntry.databaseTableName])
    let screen = try await store.load(StoryScreen.self, readNovel)
    #expect(screen.disclosure == disclosure)
    #expect(screen.faults.contains { $0.derivation == FinalChapterEntry.databaseTableName })
  }
}
