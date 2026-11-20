import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Job engine", TestTimeLimit.standard)
struct JobEngineTests {
  @Test func shouldRunATwoStepPipelineToSuccessWithEveryCallOnTheAttempt() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.reply()]))
    let engine = try world.engine()
    let job = try await world.request(engine).ref
    let handle = try await engine.run(job: job)
    #expect(await handle.result == .settled(.succeeded))
    try await world.expectOutputsWrittenOnce(job)
    let attempt = try await world.attempt(handle.attempt)
    let ledger = try await world.ledgerIDs()
    #expect(attempt.calls == ledger)
    #expect(attempt.calls.count == 2)
    #expect(world.packs.builds == 1)
    #expect(try await world.status(job) == .succeeded(handle.attempt))
    #expect(try await world.pinnedPacks() == 0)
    #expect(try await world.localRuns().isEmpty)
  }

  @Test func shouldRequestAJobOnceAndANewRunOnlyForARerunOrAfterACancel() async throws {
    let world = try await JobEngineWorld()
    let engine = try world.engine()
    let first = try await world.request(engine)
    #expect(try await world.request(engine) == first)
    #expect(first.run == 1 && first.scope == NovelJobAddress.scope(of: world.novel) && first.target == NovelJobAddress.target(chapter: 1))
    let rerun = try await world.request(engine, rerun: true)
    #expect(rerun.run == 2)
    #expect(try await world.request(engine) == rerun)
    #expect(try await engine.cancel(job: rerun.ref) == .requested)
    #expect(try await world.request(engine).run == 3)
    await #expect(throws: JobEngineError.self) { _ = try await world.request(engine, chapter: 0) }
  }

  @Test func shouldRecordThePinnedInputsOnTheAttemptStart() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.reply()]))
    let novel = world.novel
    try await world.store.write { transaction in
      _ = try EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara", age: 30).create(in: &transaction)
    }
    let engine = try world.engine()
    let job = try await world.request(engine).ref
    let handle = try await engine.run(job: job)
    #expect(await handle.result == .settled(.succeeded))
    let pins = try #require(JobPins(json: try await world.attempt(handle.attempt).start.pinned))
    let bible = try await world.store.read { transaction in try StoryBibleHash.of(novel, in: transaction) }
    #expect(pins == JobPins(pipeline: JobEngineWorld.pipelineVersion, plan: nil, upstream: DraftUpstream(entries: []), bible: bible))
    let empty = try await JobEngineWorld().store.read { transaction in try StoryBibleHash.of(novel, in: transaction) }
    #expect(bible != empty)
  }

  @Test func shouldWriteACallsIdOnTheAttemptInTheTransactionThatBeginsTheCall() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.reply()]))
    let engine = try world.engine(.once(at: .call(step: 0)))
    let job = try await world.request(engine).ref
    let handle = try await engine.run(job: job)
    #expect(await handle.result == .interrupted)
    let killed = try await world.attempt(handle.attempt)
    #expect(killed.calls.count == 1)
    let ledger = try await world.ledgerIDs()
    #expect(killed.calls == ledger)
    try await world.expectOutputsWrittenOnce(job, steps: [])
  }

  @Test func shouldCancelAnAttemptMidCallKeepingTheCutCallOnIt() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.frozen]))
    let engine = try world.engine()
    let job = try await world.request(engine).ref
    let handle = try await engine.run(job: job)
    try await world.waitForRequests(1)
    #expect(try await engine.cancel(job: job) == .requested)
    #expect(await handle.result == .settled(.cancelled))
    let attempt = try await world.attempt(handle.attempt)
    let ledger = try await world.ledgerIDs()
    #expect(attempt.calls.count == 1 && attempt.calls == ledger)
    #expect(try await world.status(job) == .cancelled)
    #expect(try await world.localRuns().isEmpty)
    try await world.expectOutputsWrittenOnce(job, steps: [])
  }

  @Test func shouldRunHereByHandOnlyOnceNoOtherDevicesLeaseIsLive() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.reply()]))
    let engine = try world.engine()
    let job = try await world.request(engine).ref
    let other = JobWorld.replicas[1]
    let foreign = try AttemptID(UUID.v7(at: world.clock.now.addingTimeInterval(-10)))
    let start = AttemptStart(job: job, replica: other, started: LeaseInstant(date: world.clock.now.addingTimeInterval(-10), source: .trusted), byHand: false, pinned: .null)
    _ = try await world.store.write { transaction in try AttemptRecords.start(foreign, start, step: AttemptStep(name: "draft", index: 0), in: &transaction) }
    for byHand in [true, false] {
      do {
        _ = try await (byHand ? engine.runHere(job: job) : engine.run(job: job))
        Issue.record("a run started beside another device's live attempt")
      } catch {
        #expect(error.code == JobEngineError.runningElsewhere(foreign, other).code)
        guard case .runningElsewhere(let attempt, let replica) = error else { continue }
        #expect(attempt == foreign && replica == other)
      }
    }
    world.clock.advance(400)
    let handle = try await engine.runHere(job: job)
    #expect(await handle.result == .settled(.succeeded))
    #expect(try await world.attempt(handle.attempt).start.byHand)
    #expect(try await world.status(job) == .succeeded(handle.attempt))
  }

  @Test func shouldResumeTheRunHeldHereWhenTheJobIsRunAgain() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.reply()]))
    let engine = try world.engine(.once(at: .afterCommit(step: 0)))
    let job = try await world.request(engine).ref
    let interrupted = try await engine.run(job: job)
    #expect(await interrupted.result == .interrupted)
    let again = try await engine.runHere(job: job)
    #expect(again.attempt == interrupted.attempt)
    #expect(await again.result == .settled(.succeeded))
    try await world.expectOutputsWrittenOnce(job)
    #expect(world.packs.builds == 1)
  }

  @Test func shouldStartAJobOnceWhenItIsRunTwiceAtOnce() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.reply()]))
    let engine = try world.engine()
    let job = try await world.request(engine).ref
    async let first = engine.run(job: job)
    async let second = engine.runHere(job: job)
    let handles = try await [first, second]
    #expect(handles[0].attempt == handles[1].attempt)
    #expect(await handles[0].result == .settled(.succeeded))
    try await world.expectOutputsWrittenOnce(job)
  }

  @Test func shouldStandDownWhenAnotherReplicasEarlierAttemptArrives() async throws {
    let reconciler = try Projection.reconciler()
    let replicas = try await CausalReplicas(
      CausalReplicaSetup(count: 2, registry: Projection.registry, migrations: reconciler.migrations, order: .causal, reconciler: { _ in reconciler }, seed: 7))
    let (here, there) = (await replicas.store(0), await replicas.store(1))
    let world = try await JobEngineWorld(store: here, provider: ScriptedModelProvider(calls: [JobEngineWorld.frozen]))
    let key = try JobWorld.key(novel: world.novel, chapter: 1)
    let request = JobRequest(key: key, payload: ["text": "seed"], replica: here.replica)
    _ = try await replicas.write(0) { transaction in try JobRecords.request(request, in: &transaction) }
    try await replicas.deliver(from: 0, to: 1)
    let engine = try world.engine()
    let handle = try await engine.run(job: key.ref)
    try await world.waitForRequests(1)
    let earlier = world.clock.now.addingTimeInterval(-10)
    let leader = try AttemptID(UUID.v7(at: earlier))
    let start = AttemptStart(job: key.ref, replica: there.replica, started: LeaseInstant(date: earlier, source: .trusted), byHand: false, pinned: .null)
    _ = try await replicas.write(1) { transaction in try AttemptRecords.start(leader, start, step: AttemptStep(name: "draft", index: 0), in: &transaction) }
    try await replicas.deliver(from: 1, to: 0)
    #expect(await handle.result == .settled(.stoodDown))
    var progress = engine.observe(job: key.ref).makeAsyncIterator()
    let seen = try #require(try await progress.next())
    #expect(seen.status == .running(leader) && seen.attempt == leader && seen.replica == there.replica && !seen.runningHere)
    #expect(try await world.attempt(handle.attempt).calls.count == 1)
  }

  @Test func shouldKeepOneEnginePerVault() async throws {
    let world = try await JobEngineWorld()
    let engine = try world.engine()
    #expect(throws: JobEngineError.self) { _ = try world.engine() }
    engine.relinquish()
    let next = try world.engine()
    engine.relinquish()
    #expect(throws: JobEngineError.self) { _ = try world.engine() }
    next.relinquish()
    do { _ = try world.engine() }
    _ = try world.engine()
  }

  @Test func shouldRefuseAKindWhosePipelineIsNotYetAvailable() async throws {
    let world = try await JobEngineWorld()
    let engine = try world.engine(catalog: { _ in .notYetAvailable(.canonRefresh) })
    let job = try await world.request(engine).ref
    do {
      _ = try await engine.runHere(job: job)
      Issue.record("a stub pipeline ran")
    } catch {
      #expect(error.code == JobEngineError.pipelineNotYetAvailable(.canonRefresh).code)
    }
  }

  @Test func shouldHaveAPipelineForEveryKind() {
    for kind in NovelJobKind.allCases {
      if case .notYetAvailable = PipelineCatalog.definition(for: kind) { Issue.record("\(kind) has no pipeline") }
    }
  }

  @Test func shouldObserveStepNamesAndReReadWhenALeaseLapses() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply()]))
    let engine = try world.engine(.once(at: .afterCommit(step: 0)))
    let job = try await world.request(engine).ref
    let handle = try await engine.run(job: job)
    #expect(await handle.result == .interrupted)
    var progress = engine.observe(job: job).makeAsyncIterator()
    let running = try #require(try await progress.next())
    #expect(running.status == .running(handle.attempt) && running.step == AttemptStep(name: "polish", index: 1) && !running.runningHere)
    #expect(running.changesAt != nil)
    try await engineEventually("the re-read is scheduled") { world.rereads.waiting > 0 }
    world.clock.advance(400)
    world.rereads.open()
    let lapsed = try #require(try await progress.next())
    #expect(lapsed.status == .queued && lapsed.changesAt == nil)
  }

  @Test func shouldRebuildTheHardLineWhenACharactersAgeChanges() async throws {
    let world = try await JobEngineWorld()
    let novel = world.novel
    try await world.store.write { transaction in
      _ = try EntityRecord(novel: novel, entity: "pip", type: .known(.character), name: "Pip", age: 15).create(in: &transaction)
    }
    let lines = NovelHardLines()
    let hit = { (lexicon: HardLineLexicon) in findHardLine(["Pip and the sex"], scope: .supplied, lexicon: lexicon) }
    #expect(hit(try await lines.lexicon(for: novel, in: world.store)) == .minorWithSexualContent)
    #expect(hit(.standard) == nil)
    var edit = EntityEdit()
    edit.age = .set(30)
    try await world.store.write { [edit] transaction in _ = try EntityRecord.edit(novel: novel, entity: "pip", edit, in: &transaction) }
    #expect(hit(try await lines.lexicon(for: novel, in: world.store)) == nil)
  }

  @Test func shouldFailAResumeIntoAChangedPipeline() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.reply()]))
    let engine = try world.engine(.once(at: .afterCommit(step: 0)))
    let job = try await world.request(engine).ref
    let handle = try await engine.run(job: job)
    #expect(await handle.result == .interrupted)
    engine.relinquish()
    let changed = NovelPipeline(version: 2, first: JobEngineWorld.pipeline.first, steps: JobEngineWorld.pipeline.steps)
    let relaunched = try world.engine(catalog: { _ in .ready(changed) })
    let resumed = try await relaunched.resumeInterruptedAttempts()
    #expect(resumed.map(\.attempt) == [handle.attempt])
    for run in resumed { _ = await run.result }
    let attempt = try await world.attempt(handle.attempt)
    #expect(attempt.outcome == .failed)
    #expect(attempt.error?.code == JobEngineError.pipelineChanged(running: 2, pinned: 1).code)
    try await world.expectOutputsWrittenOnce(job, steps: ["draft"])
  }

  @Test(arguments: [UnrestrictedMinorStep.Placement.screenedInput, .request], [false, true])
  func shouldRefuseAnUnrestrictedCallNamingAMinorBeforeAnythingIsSent(_ placement: UnrestrictedMinorStep.Placement, asText: Bool) async throws {
    let (world, handle) = try await Self.runMinorStep(placement, asText: asText, replies: [JobEngineWorld.reply()])
    #expect(try await Self.hardLineFailure(handle))
    #expect(world.provider.requests.isEmpty)
    #expect(try await world.ledgerIDs().isEmpty)
  }

  @Test(arguments: [false, true])
  func shouldRefuseAnUnrestrictedReplyNamingAMinorAndSaveNothing(asText: Bool) async throws {
    let (world, handle) = try await Self.runMinorStep(.output, asText: asText, replies: [JobEngineWorld.reply(UnrestrictedMinorStep.text)])
    #expect(try await Self.hardLineFailure(handle))
    #expect(world.provider.requests.count == 1)
    let ledger = try await world.ledgerIDs()
    let attempt = try await world.attempt(handle.attempt)
    #expect(ledger.count == 1 && attempt.calls == ledger)
    try await world.expectOutputsWrittenOnce(handle.job, steps: [])
  }

  private static func runMinorStep(
    _ placement: UnrestrictedMinorStep.Placement, asText: Bool, replies: [[ScriptedModelProvider.Step]]
  ) async throws -> (JobEngineWorld, JobRunHandle) {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: replies))
    let novel = world.novel
    try await world.store.write { transaction in
      _ = try EntityRecord(novel: novel, entity: "pip", type: .known(.character), name: "Pip", age: 15).create(in: &transaction)
    }
    let pipeline = NovelPipeline(version: JobEngineWorld.pipelineVersion, first: "draft", steps: ["draft": UnrestrictedMinorStep(placement: placement, asText: asText)])
    let engine = try world.engine(catalog: { _ in .ready(pipeline) })
    let job = try await world.request(engine).ref
    return (world, try await engine.run(job: job))
  }

  private static func hardLineFailure(_ handle: JobRunHandle) async throws -> Bool {
    guard case .settled(.failed(let failure)) = await handle.result else { return false }
    return failure.code == ChapterCallError.hardLine(HardLineHit(rule: .minorWithExplicitAct, source: "", sourceRefs: [])).code
  }

  @Test func shouldChangeTheStoryBiblePinWhenAnyStoredFieldOfAnEntityChanges() async throws {
    let world = try await JobEngineWorld()
    let novel = world.novel
    try await world.store.write { transaction in
      _ = try EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara", age: 30).create(in: &transaction)
    }
    let hash = { try await world.store.read { transaction in try StoryBibleHash.of(novel, in: transaction) } }
    var seen = [try await hash()]
    var edits = [EntityEdit(), EntityEdit()]
    edits[0].age = .set(31)
    edits[1].appearance = .set("A grey coat.")
    for edit in edits {
      try await world.store.write { transaction in _ = try EntityRecord.edit(novel: novel, entity: "mara", edit, in: &transaction) }
      seen.append(try await hash())
    }
    #expect(Set(seen).count == 3)
  }
}

/// One unrestricted chapter call, structured or text, whose minor's name and sexual act sit in exactly one place: the screened input, the request the route's
/// guard reads, or the reply the output screen reads.
struct UnrestrictedMinorStep: JobStep {
  enum Placement: Sendable {
    case screenedInput
    case request
    case output
  }

  static let text = "Pip and the orgasm."

  let placement: Placement
  let asText: Bool

  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    let route = try ChapterCallRouter.route(
      ChapterCallSource(
        novel: context.target.novel, chapter: context.target.chapter, role: .draft, plan: ChapterPlanContent(body: "Pip.", contentMode: .known(.unrestricted)),
        isolated: false), unrestrictedAvailable: true)
    let input = OrderedJSONObject([("guidance", .string(placement == .screenedInput ? Self.text : "Keep it quiet."))])
    let sent = placement == .request ? Self.text : "Write."
    let request = { (call: RoutedCall) in call.request(system: [ContextSegment(text: "Write.")], messages: [.user(sent)]) }
    let statement =
      asText
      ? try await context.callText(route, pace: .steady, screening: input, request: request).text
      : String(decoding: try await context.call(route, pace: .steady, screening: input, request: request, name: "minor", schema: FakeChapterStep.schema).json, as: UTF8.self)
    let entry = NotebookEntryRecord(novel: context.target.novel, entryKind: .known(.decision), topic: "minor", statement: statement, stepKey: "draft")
    return AttemptStepOutput(state: state, next: nil) { transaction in _ = try entry.append(in: &transaction) }
  }
}
