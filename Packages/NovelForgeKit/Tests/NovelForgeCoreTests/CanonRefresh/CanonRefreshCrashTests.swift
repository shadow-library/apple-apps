import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// A refresh killed at every runner write, inside its call and around each commit, then resumed by a new engine as a relaunch does, writes one card and one
/// report; two replicas running the same job converge on one pair.
@Suite("Canon refresh crashes and replicas", TestTimeLimit.standard)
struct CanonRefreshCrashTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let point: AttemptRunner.Faults.Point
    /// Model calls over both runs: two when the crash lost the refresh call or its output.
    let calls: Int
    let finished: Bool

    var testDescription: String { "\(point)" }
  }

  static let cases: [Case] = [
    Case(point: .committed(write: 0), calls: 1, finished: false), Case(point: .call(step: 0), calls: 2, finished: false),
    Case(point: .beforeCommit(step: 0), calls: 2, finished: false), Case(point: .afterCommit(step: 0), calls: 1, finished: false),
    Case(point: .committed(write: 1), calls: 1, finished: false), Case(point: .beforeCommit(step: 1), calls: 1, finished: false),
    Case(point: .afterCommit(step: 1), calls: 1, finished: true), Case(point: .committed(write: 2), calls: 1, finished: true),
  ]

  @Test(arguments: cases)
  func shouldWriteOneCardAndOneReportWhenKilledAndResumed(_ crash: Case) async throws {
    let world = try await RefreshWorld(replies: Array(repeating: RefreshWorld.reply([RefreshWorld.crowning]), count: 2))
    let engine = try world.engine(.once(at: crash.point))
    let key = try await engine.requestCanonRefresh(novel: world.novel, chapter: 1)
    let handle = try await engine.run(job: key.ref)
    #expect(await handle.result == .interrupted)
    engine.relinquish()

    world.engineWorld.clock.advance(5)
    let resumed = try await world.engine().resumeInterruptedAttempts()
    #expect(resumed.map(\.attempt) == (crash.finished ? [] : [handle.attempt]))
    for run in resumed { #expect(await run.result == .settled(.succeeded)) }

    #expect(world.provider.requests.count == crash.calls)
    let (writes, reports, proposals) = (try await world.writes(of: key), try await world.reports(), try await world.proposals())
    #expect(writes.card == 1 && writes.report == 1 && reports.count == 1 && proposals.count == 1)
    #expect(reports.first?.proposal == RefreshRecords.card(of: key.ref))
    #expect(try await world.engineWorld.status(key.ref) == .succeeded(handle.attempt))
  }

  // chapter-canon-refresh.service.ts:110-111: a report of the canon that arrived while the refresh ran answers the stage, which writes nothing
  @Test func shouldWriteNothingWhenAReportArrivedBeforeTheStageStep() async throws {
    let world = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])])
    let engine = try world.engine(.once(at: .afterCommit(step: 0)))
    let key = try await engine.requestCanonRefresh(novel: world.novel, chapter: 1)
    #expect(try await engine.run(job: key.ref).result == .interrupted)
    engine.relinquish()
    let (novel, digest) = (world.novel, try await world.canonDigest())
    try await world.store.write { transaction in
      _ = try RefreshReportRecord(novel: novel, chapter: 1, canonDigest: digest, findings: [], checked: [:], copy: "elsewhere").append(in: &transaction)
    }
    let resumed = try #require(try await world.engine().resumeInterruptedAttempts().first)
    #expect(await resumed.result == .settled(.succeeded))
    let (writes, reports, proposals) = (try await world.writes(of: key), try await world.reports(), try await world.proposals())
    #expect(writes.card == 0 && writes.report == 0 && reports.map(\.copy) == ["elsewhere"] && proposals.isEmpty)
  }

  // chapter-canon-refresh.service.ts:170: the card's baseline is what the refresh read, so an edit made before the card is staged conflicts at apply
  @Test func shouldStageTheCardAgainstWhatTheRefreshRead() async throws {
    let world = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])])
    let engine = try world.engine(.once(at: .afterCommit(step: 0)))
    let key = try await engine.requestCanonRefresh(novel: world.novel, chapter: 1)
    #expect(try await engine.run(job: key.ref).result == .interrupted)
    engine.relinquish()
    let novel = world.novel
    try await world.store.write { transaction in
      var edit = EntityEdit()
      edit.status = .set("Gone to sea.")
      _ = try EntityRecord.edit(novel: novel, entity: "mara", edit, in: &transaction)
    }
    let resumed = try #require(try await world.engine().resumeInterruptedAttempts().first)
    #expect(await resumed.result == .settled(.succeeded))
    let card = try #require(try await world.card(of: key))
    let waiting = try #require(try await world.store.read { transaction in try ChatWaitingOnYou.load(novel, in: transaction) }.contents.value)
    #expect(waiting.cards.isEmpty && waiting.conflicted.map(\.state.proposal) == [card.id])
  }

  private static func replicas(seed: UInt64) async throws -> CausalReplicas {
    let reconciler = try Projection.reconciler()
    return try await CausalReplicas(
      CausalReplicaSetup(count: 2, registry: Projection.registry, migrations: reconciler.migrations, order: .causal, reconciler: { _ in reconciler }, seed: seed))
  }

  private static func flush(_ replicas: CausalReplicas) async throws {
    _ = try await replicas.write(0) { _ in }
    _ = try await replicas.write(1) { _ in }
    try await replicas.settle()
  }

  // chapter-canon-refresh.service.ts:108-111, natively by canon: a canon that lost the first-writer race before the stage writes no report and no card
  @Test func shouldStageNothingWhenAnotherDevicesEarlierCanonArrivesBeforeTheStage() async throws {
    let replicas = try await Self.replicas(seed: 0x28E)
    let (here, there) = (await replicas.store(0), await replicas.store(1))
    try await RefreshWorld.seed(here, canon: nil)
    try await Self.flush(replicas)
    let novel = SchemaFixture.novel
    _ = try await replicas.write(0) { transaction in
      _ = try FinalChapterRecord(novel: novel, chapter: 1, canon: Canon(body: RefreshWorld.prose)).finalize(in: &transaction)
    }
    await replicas.advanceClock(of: 1, by: .seconds(10))
    _ = try await replicas.write(1) { transaction in
      _ = try FinalChapterRecord(novel: novel, chapter: 1, canon: Canon(body: "\(RefreshWorld.prose) Then she slept.")).finalize(in: &transaction)
    }
    let late = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])], seeded: there)
    let lost = try await late.canonDigest()
    let engine = try late.engine(.once(at: .afterCommit(step: 0)))
    let key = try await engine.requestCanonRefresh(novel: novel, chapter: 1)
    #expect(try await engine.run(job: key.ref).result == .interrupted)
    engine.relinquish()

    try await Self.flush(replicas)
    #expect(try await late.canonDigest() != lost)
    let resumed = try #require(try await late.engine().resumeInterruptedAttempts().first)
    #expect(await resumed.result == .settled(.succeeded))
    let (writes, reports, proposals) = (try await late.writes(of: key), try await late.reports(), try await late.proposals())
    #expect(late.provider.requests.count == 1 && writes.card == 0 && writes.report == 0 && reports.isEmpty && proposals.isEmpty)
  }

  /// Pins today's merge: the earlier replica's report, which withheld everything, wins the report's first-writer race, while the later replica's card, which no
  /// other write races, still stands and waits on the author. A reader must take the winning report's `proposal` as the job's card.
  @Test func shouldKeepTheEarlierReportAndTheLaterCardWhenTwoReplicasDisagree() async throws {
    let replicas = try await Self.replicas(seed: 0x28F)
    let (here, there) = (await replicas.store(0), await replicas.store(1))
    try await RefreshWorld.seed(here)
    let later = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])], seeded: here)
    let engine = try later.engine()
    let key = try await engine.requestCanonRefresh(novel: later.novel, chapter: 1)
    try await Self.flush(replicas)

    let kael = RefreshWorld.update(
      "Kael appears for the first time.", quotes: [("chapter:1", "crowned herself queen of the salt road")],
      ops: [jsonObject([("op", .string("entity.upsert")), ("entityKey", .string("kael")), ("type", .string("character")), ("status", .string("A guard."))])])
    let earlier = try await RefreshWorld(replies: [RefreshWorld.reply([kael])], seeded: there)
    #expect(try await earlier.engine().run(job: key.ref).result == .settled(.succeeded))
    await replicas.advanceClock(of: 0, by: .seconds(10))
    #expect(try await engine.run(job: key.ref).result == .settled(.succeeded))
    try await Self.flush(replicas)

    for world in [later, earlier] {
      let (reports, proposals, card) = (try await world.reports(), try await world.proposals(), try await world.card(of: key))
      let report = try #require(reports.first)
      #expect(reports.count == 1 && report.proposal == nil && report.findings.first?["withheld"] == .string(RefreshWithheld.newRecord))
      #expect(card?.decision == .known(.pending) && proposals.map(\.proposal) == [RefreshRecords.card(of: key.ref)])
    }
  }

  @Test(arguments: [UInt64(0x28A), 0x28B])
  func shouldConvergeOnOneCardAndOneReportWhenTwoReplicasRunTheJob(seed: UInt64) async throws {
    let reconciler = try Projection.reconciler()
    let replicas = try await CausalReplicas(
      CausalReplicaSetup(count: 2, registry: Projection.registry, migrations: reconciler.migrations, order: .causal, reconciler: { _ in reconciler }, seed: seed))
    let (here, there) = (await replicas.store(0), await replicas.store(1))
    try await RefreshWorld.seed(here)
    let first = try await RefreshWorld(replies: [RefreshWorld.reply([RefreshWorld.crowning])], seeded: here)
    let other = RefreshWorld.update(
      "Mara wears the crown now.", quotes: [("chapter:1", "took the iron crown from the harbour vault")],
      ops: [jsonObject([("op", .string("entity.upsert")), ("entityKey", .string("mara")), ("type", .string("character")), ("status", .string("The crowned queen."))])])
    let engine = try first.engine()
    let key = try await engine.requestCanonRefresh(novel: first.novel, chapter: 1)
    _ = try await replicas.write(0) { _ in }
    try await replicas.settle()

    let second = try await RefreshWorld(replies: [RefreshWorld.reply([other, RefreshWorld.crowning])], seeded: there)
    #expect(try await engine.run(job: key.ref).result == .settled(.succeeded))
    #expect(try await second.engine().run(job: key.ref).result == .settled(.succeeded))
    _ = try await replicas.write(0) { _ in }
    _ = try await replicas.write(1) { _ in }
    try await replicas.settle()

    var seen = [String]()
    for world in [first, second] {
      let (reports, proposals) = (try await world.reports(), try await world.proposals())
      let card = try #require(try await world.card(of: key))
      let report = try #require(reports.first)
      #expect(reports.count == 1 && proposals.count == 1 && report.proposal == card.id && card.card.summary == report.copy)
      seen.append(report.copy)
    }
    #expect(Set(seen).count == 1)
  }
}
