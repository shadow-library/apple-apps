import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("SyncEngine adoption")
struct SyncAdoptTests {
  @Test("should carry the whole fact in its key, read a fact only from its canonical key, and read it from a purged entity")
  func shouldPinFactKey() async throws {
    let adopted = ReplicaFixture.replica("01936f3e-1111-7111-8111-111111111111")
    let adopter = ReplicaFixture.replica("01936f3e-2222-7222-8222-222222222222")
    let fact = SyncAdoptionFact(adopted: adopted, adopter: adopter, through: 42, at: 7, baseUpTo: 30)
    let key = ReplicaFixture.key("01936f3e-1111-7111-8111-111111111111:01936f3e-2222-7222-8222-222222222222:42:7:30")
    #expect(SyncKernelSchema.adoptionRef(fact) == EntityRef(kind: ReplicaFixture.kind("_adoption"), key: key))
    #expect(SyncKernelSchema.adoption(of: key) == fact)
    let malformed = [
      "\(adopted):\(adopter):042:7:30", "\(adopted):\(adopter):42:0:30", "\(adopted):\(adopted):42:7:30", "\(adopted):\(adopter):42:7",
      "\(adopted):\(adopter):42:7:30:1", "\(adopted):\(adopter):1000000000000:7:30", "\(adopted):\(adopter):-1:7:30", "\(adopted):\(adopter):42:7:030", "v-7",
    ]
    for text in malformed { #expect(SyncKernelSchema.adoption(of: ReplicaFixture.key(text)) == nil, "\(text)") }

    let store = try SyncFixture.open()
    try await store.write { transaction in try ReplicaDirectory.recordAdoption(fact, in: &transaction) }
    try await store.write { transaction in try ReplicaDirectory.recordAdoption(fact, in: &transaction) }
    #expect(try await store.pendingChanges(limit: .max).count == 1)
    _ = try await store.write { transaction in try transaction.purge(SyncKernelSchema.adoptionRef(fact)) }
    try await store.write { transaction in try ReplicaDirectory.recordAdoption(fact, in: &transaction) }
    let directory = try await store.read { ReplicaDirectory(entities: try $0.states(ofKind: SyncKernelSchema.adoptionKind)) }
    #expect(directory.adoptions == [fact])
  }

  @Test("should fold a retired replica into the adopter's base, delete its prefix and leave every reader with every change")
  func shouldAdoptRetiredReplica() async throws {
    let scenario = try await SyncAdoptScenario.make()
    let retired = scenario.retiredID
    let head = try #require(try await scenario.retiredStore.read { try ReplicaHistory.head(of: retired, in: $0.database) })

    #expect(try await scenario.adopter.engine.adopt() == .adopted([retired]))

    try await scenario.expectAdopted(by: scenario.adopter)
    let fact = try #require(try await SyncAdoptCheck.facts(scenario.adopter).first)
    #expect(fact.adopted == retired && fact.adopter == scenario.adopterID && fact.through == head.last && fact.at >= 1)
    #expect(try await SyncAdoptCheck.rows(scenario.adopter)[retired]?.phase == .finished)
    #expect(try await scenario.adopter.engine.adopt() == .nothingToAdopt)
    try await scenario.expectConverges(try await scenario.freshReader("fresh"), "fresh")
    try await scenario.expectConverges(scenario.half, "half")
    try await scenario.expectConverges(scenario.bystander, "bystander")
    _ = try await scenario.adopter.engine.download()
    #expect(try await scenario.adopter.digest() == (try await scenario.reference(also: try await scenario.adopter.pendingLines())))
  }
}
