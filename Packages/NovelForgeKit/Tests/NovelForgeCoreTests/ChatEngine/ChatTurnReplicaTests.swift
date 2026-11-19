import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld

private let stalled: [ScriptedModelProvider.Step] = [.event(.started(requestID: "req", generationID: nil)), .text(#"{"reply":"Thinking it"#), .delay(.seconds(120))]

// Orchestrator decision 6: a device that sees a message being answered elsewhere can answer it here, and both replies stand.
@Suite("Chat turns on two devices", TestTimeLimit.standard)
struct ChatTurnReplicaTests {
  @Test func shouldKeepBothRepliesWhenTwoDevicesAnswerOneMessage() async throws {
    let reconciler = try ChatWorld.reconciler()
    let replicas = try await CausalReplicas(
      CausalReplicaSetup(count: 2, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: 0xF22B))
    let novel = ChatWorld.novel
    _ = try await replicas.write(0) { transaction in
      _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
      _ = try ChatSessionRecord(id: World.session, novel: novel).create(in: &transaction)
    }
    try await replicas.settle()
    let (here, there) = (await replicas.store(0), await replicas.store(1))

    let first = try await World.engine(here, provider: ScriptedModelProvider(calls: [stalled]))
    let handle = try await first.send("Who betrays Mara?", session: World.session, novel: novel)
    _ = try await replicas.write(0) { _ in }
    try await replicas.settle()

    let elsewhere = try await World.engine(there, provider: ScriptedModelProvider(calls: [World.reply(("reply", World.text("Kael, in chapter four.")))]))
    #expect(try await elsewhere.activity(session: World.session) == .answeringElsewhere(message: handle.userMessage))
    let answer = try World.reply(of: await elsewhere.answer(message: handle.userMessage, session: World.session, novel: novel).outcome())

    first.interrupt(turn: handle.turn)
    #expect(await handle.outcome() == .interrupted)
    let resumed = try await World.engine(here, provider: ScriptedModelProvider(calls: [World.reply(("reply", World.text("Nobody yet.")))]))
      .resumeInterruptedTurns()
    let own = try World.reply(of: await resumed[0].outcome())
    _ = try await replicas.write(0) { _ in }
    _ = try await replicas.write(1) { _ in }
    try await replicas.settle()

    for store in [here, there] {
      let messages = try await World.messages(in: store)
      #expect(messages.count == 3)
      #expect(messages.filter { $0.role == .known(.assistant) }.map(\.answers) == [handle.userMessage, handle.userMessage])
      #expect(Set(messages.map(\.id)) == [handle.userMessage, answer, own])
    }
    #expect(try await first.activity(session: World.session) == .idle)
  }
}
