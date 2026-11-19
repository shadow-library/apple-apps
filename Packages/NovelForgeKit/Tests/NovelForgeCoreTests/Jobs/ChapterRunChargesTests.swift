import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore
import Testing

@testable import NovelForgeCore
@testable import ShadowAI

private typealias World = JobWorld

@Suite("Chapter run charges")
struct ChapterRunChargesTests {
  private static let query = ChapterRunChargesQuery(novel: World.novel, chapter: 1)

  @Test func shouldSumTheCallsOfEveryAttemptPerRunAndForTheChapter() async throws {
    let (_, store) = try World.store()
    let first = try await World.request(try World.key(run: 1), in: store)
    let second = try await World.request(try World.key(run: 2), in: store)
    let elsewhere = try await World.request(try World.key(chapter: 2), in: store)
    let (firstAttempt, retry) = (try await World.start(first, at: 0, seed: 1, in: store), try await World.start(first, at: 100, seed: 2, in: store))
    let secondAttempt = try await World.start(second, at: 200, seed: 3, in: store)
    _ = try await World.start(elsewhere, at: 0, seed: 4, in: store)
    try await World.ledger(World.calls[0], events: World.finishedEvents(300), in: store)
    try await World.ledger(World.calls[1], events: World.finishedEvents(200), in: store)
    try await World.ledger(World.calls[2], events: World.finishedEvents(50), in: store)
    try await World.update(firstAttempt, AttemptUpdate(call: World.calls[0]), in: store)
    try await World.update(retry, AttemptUpdate(call: World.calls[1]), in: store)
    try await World.update(secondAttempt, AttemptUpdate(call: World.calls[2]), in: store)

    let charges = try await store.load(ChapterRunCharges.self, Self.query)
    let runs = try #require(charges.runs.value)
    #expect(runs.map(\.run) == [2, 1])
    #expect(runs.map(\.job) == [second, first])
    #expect(runs.map(\.cost.cost) == [Cost(nanoUSD: 50), Cost(nanoUSD: 500)])
    #expect(runs.allSatisfy { $0.kind == .known(.generate) })
    #expect(charges.total.value?.cost == Cost(nanoUSD: 550) && charges.total.value?.calls == 3 && charges.total.value?.isPending == false)
  }

  @Test func shouldReadAJobWithoutCallsAsZeroAndAStoodDownCallAsPending() async throws {
    let (_, store) = try World.store()
    try await World.request(try World.key(run: 1), in: store)
    let stood = try await World.request(try World.key(run: 2), in: store)
    let attempt = try await World.start(stood, at: 0, in: store)
    let start = World.callStart(World.calls[0])
    _ = try await Projection.write(store) { transaction in try Ledger.begin(start, in: &transaction) }
    try await World.update(attempt, AttemptUpdate(call: World.calls[0]), in: store)

    let charges = try await store.load(ChapterRunCharges.self, Self.query)
    let byRun = Dictionary(uniqueKeysWithValues: try #require(charges.runs.value).map { ($0.run, $0.cost) })
    #expect(byRun[1] == .zero && byRun[1]?.isPending == false)
    #expect(byRun[2]?.isPending == true && byRun[2]?.cost == .zero && byRun[2]?.pendingCalls == 1)
    #expect(charges.total.value?.isPending == true)
  }

  @Test func shouldReadUnavailableWhenTheCostTablesFault() async throws {
    let (_, store) = try World.store()
    _ = try await World.request(try World.key(), in: store)
    try await ReadWorld.insertFault(JobCallCost.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    let charges = try await store.load(ChapterRunCharges.self, Self.query)
    #expect(charges.runs.isUnavailable && charges.total.isUnavailable && !charges.faults.isEmpty)
  }
}
