import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

@Suite("Bible records across replicas", .timeLimit(.minutes(5)))
struct BibleReplicaTests {
  @Test func shouldLetASecretRemovalWithALaterClockWinOverAnEdit() async throws { try await removalWinsOverAnEditWithAnEarlierClock(SecretSubject.self, seed: 0x15) }
  @Test func shouldLetAnEntityRemovalWithALaterClockWinOverAnEdit() async throws { try await removalWinsOverAnEditWithAnEarlierClock(EntitySubject.self, seed: 0x16) }
  @Test func shouldLetARetractionWithALaterClockWinOverAnEditOfAManualReveal() async throws {
    try await removalWinsOverAnEditWithAnEarlierClock(CharacterKnowledgeSubject.self, seed: 0x17)
  }

  @Test func shouldKeepARemovedSecretRemovedWhenAnEditFollowsAndRestoreItOnlyOnRestore() async throws { try await anEditAfterARemovalDoesNotRevive(SecretSubject.self, seed: 0x25) }
  @Test func shouldKeepARemovedEntityRemovedWhenAnEditFollowsAndRestoreItOnlyOnRestore() async throws { try await anEditAfterARemovalDoesNotRevive(EntitySubject.self, seed: 0x26) }
  @Test func shouldKeepARetractedManualRevealRetractedWhenAnEditFollowsAndRestoreItOnlyOnRestore() async throws {
    try await anEditAfterARemovalDoesNotRevive(CharacterKnowledgeSubject.self, seed: 0x27)
  }

  @Test func shouldMergeSecretFieldsEditedOnDifferentReplicas() async throws { try await fieldsEditedOnDifferentReplicasMerge(SecretSubject.self, seed: 0x35) }
  @Test func shouldMergeEntityFieldsEditedOnDifferentReplicas() async throws { try await fieldsEditedOnDifferentReplicasMerge(EntitySubject.self, seed: 0x36) }

  @Test func shouldTakeAConcurrentlyCreatedSecretWholeFromTheLaterCreate() async throws { try await concurrentCreatesComeWholeFromOneReplica(SecretSubject.self, seed: 0x45) }
  @Test func shouldTakeAConcurrentlyCreatedEntityWholeFromTheLaterCreate() async throws { try await concurrentCreatesComeWholeFromOneReplica(EntitySubject.self, seed: 0x46) }
  @Test func shouldTakeAConcurrentlyCreatedManualRevealWholeFromTheLaterCreate() async throws {
    try await concurrentCreatesComeWholeFromOneReplica(CharacterKnowledgeSubject.self, seed: 0x47)
  }

  @Test func shouldSettleSecretsToTheSameRecordsOnEveryReplicaWithEachClueGroupWhole() async throws { try await settlesToTheSameRecordsEverywhere(SecretSubject.self, seed: 0x55) }
  @Test func shouldSettleEntitiesToTheSameRecordsOnEveryReplica() async throws { try await settlesToTheSameRecordsEverywhere(EntitySubject.self, seed: 0x56) }
  @Test func shouldSettleManualRevealsToTheSameRecordsOnEveryReplicaWithEachRevealWhole() async throws {
    try await settlesToTheSameRecordsEverywhere(CharacterKnowledgeSubject.self, seed: 0x57)
  }
}
