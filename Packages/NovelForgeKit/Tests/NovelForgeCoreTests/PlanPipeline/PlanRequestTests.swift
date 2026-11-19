import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Plan requests", .timeLimit(.minutes(3)))
struct PlanRequestTests {
  static let session = SchemaFixture.uuid("00000000-0000-4000-8000-0000000000c1")

  static func origin(message: UUID? = nil, proposal: UUID = SchemaFixture.uuid("00000000-0000-4000-8000-0000000000e9")) -> ChapterPlanOrigin {
    ChapterPlanOrigin(session: session, message: message, proposal: proposal, opIndex: 0)
  }

  // Orchestrator decision 8: the steer's every part is in the fingerprint, so a plan differing in any one is another job, refused while the first is open (PLN_009)
  @Test func shouldTellPlansApartByDirectionAndByEmptiness() async throws {
    let world = try await PlanJobWorld()
    let engine = try world.engine()
    let first = try await world.request(engine, steer: .card(intent: nil, direction: "Kael returns", origin: Self.origin()))
    let same = try await world.request(engine, steer: .card(intent: nil, direction: "Kael returns", origin: Self.origin()))
    #expect(same.deduped && same.job == first.job)
    #expect(await world.refusal(engine, steer: .card(intent: nil, direction: "Mara leaves", origin: Self.origin()))?.code == "PLN_009")
    #expect(await world.refusal(engine, steer: .card(intent: nil, direction: "Kael returns", origin: Self.origin()), empty: true)?.code == "PLN_009")
  }

  // plan-job.service.ts:51-59, 66: the author's words count only after the chat's previous plan card, ranked by the order cards were staged in
  @Test func shouldReadOnlyTheAuthorsMessagesAfterTheChatsPreviousPlanCard() async throws {
    let ids = (1...4).map { SchemaFixture.uuid(String(format: "00000000-0000-4000-8000-0000000000d%d", $0)) }
    let (earlierCard, originCard) = (SchemaFixture.uuid("00000000-0000-4000-8000-0000000000e1"), SchemaFixture.uuid("00000000-0000-4000-8000-0000000000e2"))
    let world = try await PlanJobWorld { novel, transaction in _ = try ChatSessionRecord(id: Self.session, novel: novel).create(in: &transaction) }
    let novel = world.novel
    let turns: [(ChatRole, String)] = [(.user, "She sells the lamp."), (.assistant, "Here is a plan."), (.user, "Now the next one."), (.assistant, "Shall I plan it?")]
    for (id, turn) in zip(ids, turns) {
      try await world.store.write { transaction in
        _ = try ChatMessageRecord(id: id, novel: novel, session: Self.session, role: turn.0, content: turn.1, passageContexts: []).append(in: &transaction)
      }
    }
    for (card, message, op) in [
      (earlierCard, ids[1], #"{"op":"brief.update","chapter":1,"body":"Mara sells the lamp."}"#), (originCard, ids[3], #"{"op":"action.plan_chapter"}"#),
    ] {
      try await world.store.write { transaction in
        let changeSet = try ValidatedChangeSet(.array([try OrderedJSON(parsing: op)]))
        let input = ProposalStagingInput(novel: novel, session: Self.session, message: message, kind: card == earlierCard ? .chapterPlan : .chat, changeSet: changeSet)
        _ = try ProposalStager.stage(input, id: card, in: &transaction)
      }
    }
    let engine = try world.engine()
    let after = try await world.request(engine, steer: .card(intent: "She sells the lamp", direction: nil, origin: Self.origin(message: ids[3], proposal: originCard)))
    let payload = try await world.store.read { transaction in try JobRecords.read(after.job.ref, in: transaction).record?.request.payload }
    #expect(payload?["intent"] == nil && payload?["direction"] == .string("She sells the lamp"))
    _ = try await engine.cancel(job: after.job.ref)

    let before = try await world.request(engine, steer: .card(intent: "She sells the lamp", direction: nil, origin: Self.origin(message: ids[1], proposal: earlierCard)))
    let held = try await world.store.read { transaction in try JobRecords.read(before.job.ref, in: transaction).record?.request.payload }
    #expect(held?["intent"] == .string("She sells the lamp"))
  }
}
