import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Job engine start gates", TestTimeLimit.standard)
struct JobEngineStartGateTests {
  @Test func shouldStartNoAttemptWithoutConsentAndRunTheJobOnceItIsGiven() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.reply()]))
    try await Self.decide(.revoked, at: 2, in: world)
    let engine = try world.engine()
    defer { engine.relinquish() }
    let key = try await world.request(engine)

    let refused = await #expect(throws: JobEngineError.self) { _ = try await engine.run(job: key.ref) }
    guard case .consentRequired(let request)? = refused else { throw StartGateFixtureError.unexpected(String(describing: refused)) }
    #expect(request.host == "api.example.com" && refused?.code == "routing.consent_required")
    let snapshot = try await world.store.read { transaction in try JobSnapshot.load(key.ref, in: transaction) }
    let runs = try await world.localRuns()
    #expect(snapshot?.attempts.isEmpty == true && runs.isEmpty && world.provider.requests.isEmpty)

    try await Self.decide(.granted, at: 3, in: world)
    #expect(await (try await engine.run(job: key.ref)).result == .settled(.succeeded))
  }

  @Test func shouldCheckTheUnrestrictedHostsConsentForAnUnrestrictedJob() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.reply()]))
    try await Self.decide(.revoked, at: 2, host: "router.example.com", in: world)
    let engine = try world.engine(unrestrictedAvailable: true)
    defer { engine.relinquish() }
    let raised = try await engine.request(
      NovelJobRequest(kind: .generate, novel: world.novel, chapter: 1, fingerprint: "raised", payload: ["text": "seed", "unrestricted": true]))

    let refused = await #expect(throws: JobEngineError.self) { _ = try await engine.run(job: raised.ref) }
    guard case .consentRequired(let request)? = refused else { throw StartGateFixtureError.unexpected(String(describing: refused)) }
    #expect(request.host == "router.example.com" && request.provider == .openRouter)
    let snapshot = try await world.store.read { transaction in try JobSnapshot.load(raised.ref, in: transaction) }
    #expect(snapshot?.attempts.isEmpty == true && world.provider.requests.isEmpty)

    let standard = try await world.request(engine, chapter: 2)
    #expect(await (try await engine.run(job: standard.ref)).result == .settled(.succeeded))
  }

  @Test func shouldRequestTheNextRunOfAJobWhoseHighestRunFailed() async throws {
    let calls = [[ScriptedModelProvider.Step.failure(.server(status: 500))], JobEngineWorld.reply(), JobEngineWorld.reply()]
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: calls))
    let engine = try world.engine()
    defer { engine.relinquish() }
    let first = try await world.request(engine)
    guard case .settled(.failed) = await (try await engine.run(job: first.ref)).result else { throw StartGateFixtureError.unexpected("the first run did not fail") }

    let second = try await world.request(engine)
    #expect(second.run == 2 && second.ref != first.ref)
    #expect(try await world.request(engine) == second)
    #expect(await (try await engine.run(job: second.ref)).result == .settled(.succeeded))
    #expect(try await world.request(engine) == second)
  }

  private static func decide(_ state: AIConsentState, at millis: Int64, host: String = "api.example.com", in world: JobEngineWorld) async throws {
    let consent = CompactionWorld.consent
    try await world.store.write { transaction in
      try AIConsent.decide(state, provider: host, dataClass: consent.dataClass, summary: consent.disclosure, atMillis: millis, in: &transaction)
    }
  }
}

private enum StartGateFixtureError: Error {
  case unexpected(String)
}
