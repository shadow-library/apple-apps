import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld
private typealias Crash = CrashWorld

// Orchestrator decision 6: device A crashes after staging its turn, device B answers the same message with `Answer here`, and A's relaunch finishes its own
// turn from what it staged: both replies stand, and A's resume applies nothing again
@Suite("Chat turns killed on one device and answered on another", .serialized, TestTimeLimit.standard)
struct ChatTurnDeviceCrashTests {
  @Test(arguments: [false, true])
  func shouldKeepBothRepliesAndNeverApplyTwiceWhenAnotherDeviceAnswersACrashedTurn(sameChanges: Bool) async throws {
    let reconciler = try ChatWorld.reconciler()
    let replicas = try await CausalReplicas(
      CausalReplicaSetup(count: 2, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: 0xF27))
    let novel = ChatWorld.novel
    _ = try await replicas.write(0) { transaction in
      _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
      try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
      try PlanWorldWrites.milestone(novel: novel, "rise", in: &transaction)
      _ = try ChatSessionRecord(id: World.session, novel: novel).create(in: &transaction)
    }
    try await replicas.settle()
    let (here, there) = (await replicas.store(0), await replicas.store(1))

    let crashing = try await Crash.engine(here, provider: ScriptedModelProvider(calls: [Crash.split()]), faults: World.faults(.crash, at: .staged))
    let handle = try await crashing.send(World.message, session: World.session, novel: novel)
    #expect(await handle.outcome() == .interrupted)
    let steps = try #require(try await World.steps(of: handle.turn, in: here))
    guard case .applied(let applied, true)? = steps.first, case .cards(let card?)? = steps.last else {
      Issue.record("staging did not record both steps: \(steps)")
      return
    }
    _ = try await replicas.write(0) { _ in }
    try await replicas.settle()

    let answer =
      sameChanges ? Crash.split() : World.reply(("reply", World.text("Kael, in chapter four.")))
    let elsewhere = try await Crash.engine(there, provider: ScriptedModelProvider(calls: [answer]))
    #expect(try await elsewhere.activity(session: World.session) == .answeringElsewhere(message: handle.userMessage))
    let otherReply = try World.reply(of: await elsewhere.answer(message: handle.userMessage, session: World.session, novel: novel).outcome())
    _ = try await replicas.write(1) { _ in }
    try await replicas.settle()

    let before = try await Crash.footprint(in: here)
    let idle = ScriptedModelProvider()
    let relaunched = try await Crash.engine(here, provider: idle)
    let resumed = try #require(try await relaunched.resumeInterruptedTurns().first)
    let ownReply = try World.reply(of: await resumed.outcome())
    #expect(ownReply == handle.turn && idle.requests.isEmpty)
    let after = try await Crash.footprint(in: here)
    #expect(after.proposals == before.proposals && after.changeRows == before.changeRows && after.hashes == before.hashes)
    _ = try await replicas.write(0) { _ in }
    try await replicas.settle()

    for store in [here, there] {
      let messages = try await World.messages(in: store)
      #expect(messages.count == 3)
      #expect(Set(messages.filter { $0.role == .known(.assistant) }.map(\.id)) == [ownReply, otherReply])
      #expect(messages.filter { $0.role == .known(.assistant) }.allSatisfy { $0.answers == handle.userMessage })
      let own = try #require(messages.first { $0.id == ownReply })
      #expect(own.appliedProposal == applied && own.cardProposal == card)
      let proposals = try await store.read { try ProposalRecord.listing(in: $0).entries.map(\.record) }
      #expect(proposals.allSatisfy { proposal in messages.contains { $0.id == proposal.card.message } })
      #expect(proposals.count(where: { $0.card.message == ownReply }) == 2)
      #expect(proposals.count(where: { $0.application?.automatic == true && $0.card.message == ownReply }) == 1)
      #expect(try await store.pendingLocalTurns().isEmpty)
    }
    #expect(try await Crash.footprint(in: here) == Crash.footprint(in: there))
    #expect(try await relaunched.activity(session: World.session) == .idle)
  }
}
