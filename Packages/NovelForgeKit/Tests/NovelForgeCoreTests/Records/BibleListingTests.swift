import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

@Suite("Bible record listing", .timeLimit(.minutes(1)))
struct BibleListingTests {
  @Test func shouldListOnlyTheSecretsOfTheNovel() async throws { try await listsOnlyTheNovelsOwnRecords(SecretSubject.self, seed: 0xF7) }
  @Test func shouldListOnlyTheEntitiesOfTheNovel() async throws { try await listsOnlyTheNovelsOwnRecords(EntitySubject.self, seed: 0xF8) }
  @Test func shouldListOnlyTheManualRevealsOfTheNovel() async throws { try await listsOnlyTheNovelsOwnRecords(CharacterKnowledgeSubject.self, seed: 0xFA) }

  @Test func shouldSkipUnreadableSecretsAndCountThem() async throws { try await skipsUnreadableAndCountsThem(SecretSubject.self) }
  @Test func shouldSkipUnreadableEntitiesAndCountThem() async throws { try await skipsUnreadableAndCountsThem(EntitySubject.self) }
  @Test func shouldSkipUnreadableManualRevealsAndCountThem() async throws { try await skipsUnreadableAndCountsThem(CharacterKnowledgeSubject.self) }
}
