import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

private final class JobTestClock: Sendable {
  private let date = Mutex(Date(timeIntervalSince1970: 1_700_000_000))

  var function: @Sendable () -> Date { { self.date.withLock { $0 } } }

  func advance() {
    date.withLock { $0 = $0.addingTimeInterval(1) }
  }
}

private struct JobDevices {
  static let registry = SchemaRegistry(version: 1, entities: JobSchema.entities)

  let clock = JobTestClock()
  let first: VaultStore
  let second: VaultStore

  init() throws {
    first = try VaultStore.open(.inMemory, registry: Self.registry, wallClock: clock.function)
    second = try VaultStore.open(.inMemory, registry: Self.registry, wallClock: clock.function)
  }

  var both: [VaultStore] { [first, second] }

  func exchange() async throws {
    let fromFirst = try await first.pendingChanges(limit: Int.max).map(\.line)
    let fromSecond = try await second.pendingChanges(limit: Int.max).map(\.line)
    _ = try await second.applyRemote(fromFirst)
    _ = try await first.applyRemote(fromSecond)
  }

  func set(_ ref: EntityRef, _ fields: [String: JSONValue], in store: VaultStore) async throws {
    _ = try await store.write { transaction in try transaction.set(ref, fields) }
    clock.advance()
  }

  func agreed(_ ref: EntityRef) async throws -> RecordState {
    let states = try await both.asyncMap { store in try await store.read { transaction in try transaction.state(of: ref) } }
    guard case .record(let record)? = states[0] else { throw JobTestError(description: "\(ref.kind)/\(ref.key) is not a record") }
    #expect(states[1] == states[0])
    return record
  }
}

private struct JobTestError: Error, CustomStringConvertible {
  let description: String
}

extension Array {
  fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
    var mapped = [T]()
    for element in self { mapped.append(try await transform(element)) }
    return mapped
  }
}

@Suite("JobSchema", TestTimeLimit.quick)
struct JobSchemaTests {
  private static let novel = "6f0c4d1e-0000-4000-8000-000000000001"

  private static func key(target: String = "chapter:3", fingerprint: String = "f0", run: Int = 1) throws -> JobKey {
    try JobKey(scope: novel, kind: "generate", target: target, fingerprint: fingerprint, run: run)
  }

  private static func attempt() throws -> EntityRef { try AttemptID(UUID.v7()).ref }

  @Test func shouldDeclareTheJobAndAttemptKindsWithTheirMergeRules() throws {
    let registry = JobDevices.registry
    #expect(
      registry[JobSchema.jobKind]?.shape == .record(fields: ["request": .firstWriterWins, "cancel": .monotone(order: ["none", "requested"])]))
    #expect(
      registry[JobSchema.attemptKind]?.shape
        == .record(fields: [
          "start": .firstWriterWins, "lease": .register, "step": .register, "calls": .register,
          "outcome": .monotone(order: ["running", "failed", "stood_down", "cancelled", "succeeded"]), "error": .firstWriterWins,
        ]))
    #expect(JobSchema.entities.allSatisfy { $0.syncClass == .general })
    #expect(JobSchema.entities.map(\.kind.rawValue) == ["jobs_job", "jobs_attempt"])
  }

  @Test func shouldHashTheJobUnderTheShadowJobsDomainFromScopeKindTargetFingerprintThenTheDecimalRun() throws {
    let key = try Self.key(run: 12)
    let expected = EntityKey.natural(
      scope: "com.shadow.library.shadowjobs.job", kind: JobSchema.jobKind, components: [Self.novel, "generate", "chapter:3", "f0", "12"])
    #expect(key.ref == EntityRef(kind: JobSchema.jobKind, key: expected))
    #expect(key.ref.key.rawValue == "n:6813e13f118f580dd5c44ad61961eea7b752f4e2")
    #expect(key.requestMembers == ["scope": .string(Self.novel), "kind": "generate", "target": "chapter:3", "fingerprint": "f0", "run": 12])
  }

  @Test func shouldGiveEveryComponentItsOwnJob() throws {
    let keys = try [
      Self.key(), Self.key(target: "chapter:4"), Self.key(fingerprint: "f1"), Self.key(run: 2),
      JobKey(scope: "6f0c4d1e-0000-4000-8000-000000000002", kind: "generate", target: "chapter:3", fingerprint: "f0", run: 1),
      JobKey(scope: Self.novel, kind: "review", target: "chapter:3", fingerprint: "f0", run: 1),
      JobKey(scope: Self.novel, kind: "generate", target: "chapter:3f", fingerprint: "0", run: 1),
    ]
    #expect(Set(keys.map(\.ref)).count == keys.count)
  }

  @Test func shouldGiveThePrecomposedAndDecomposedSpellingsOneJob() throws {
    let precomposed = try JobKey(scope: Self.novel, kind: "generate", target: "entity:Am\u{E9}lie", fingerprint: "f0", run: 1)
    let decomposed = try JobKey(scope: Self.novel, kind: "generate", target: "entity:Ame\u{301}lie", fingerprint: "f0", run: 1)
    #expect(precomposed.ref == decomposed.ref)
    #expect(Array(decomposed.target.utf8) == Array("entity:Am\u{E9}lie".utf8))
  }

  @Test func shouldRefuseAnEmptyComponentAndARunBeforeOne() {
    #expect(throws: JobKeyError.emptyComponent("scope")) { try JobKey(scope: "", kind: "generate", target: "t", fingerprint: "f", run: 1) }
    #expect(throws: JobKeyError.emptyComponent("kind")) { try JobKey(scope: Self.novel, kind: "", target: "t", fingerprint: "f", run: 1) }
    #expect(throws: JobKeyError.emptyComponent("target")) { try JobKey(scope: Self.novel, kind: "generate", target: "", fingerprint: "f", run: 1) }
    #expect(throws: JobKeyError.emptyComponent("fingerprint")) { try JobKey(scope: Self.novel, kind: "generate", target: "t", fingerprint: "", run: 1) }
    #expect(throws: JobKeyError.runOutOfRange(0)) { try Self.key(run: 0) }
    #expect(throws: JobKeyError.runOutOfRange(-1)) { try Self.key(run: -1) }
  }

  @Test func shouldReadTheKeyBackFromAStoredRequestAndRefuseOneThatHashesElsewhere() throws {
    let key = try Self.key(run: 3)
    let request = JSONValue.object(key.requestMembers.merging(["payload": ["chapter": 3], "replica": "r1"]) { first, _ in first })
    let decoded = try JSONDecoder().decode(JSONValue.self, from: CanonicalJSON.encode(request))
    #expect(try JobKey(request: decoded, of: key.ref) == key)
    #expect(throws: JobKeyError.keyMismatch(key.ref)) { try JobKey(request: .object(try Self.key(run: 4).requestMembers), of: key.ref) }
    var malformed = key.requestMembers
    malformed["run"] = "3"
    #expect(throws: JobKeyError.malformedKey("run is not an integer")) { try JobKey(request: .object(malformed), of: key.ref) }
    malformed = key.requestMembers
    malformed["scope"] = nil
    #expect(throws: JobKeyError.malformedKey("scope is not a string")) { try JobKey(request: .object(malformed), of: key.ref) }
    #expect(throws: JobKeyError.malformedKey("it is not an object")) { try JobKey(request: "generate", of: key.ref) }
  }

  @Test func shouldTakeOnlyAVersionSevenAttemptID() throws {
    let random = try #require(UUID(uuidString: "6f0c4d1e-0000-4000-8000-000000000001"))
    #expect(throws: JobKeyError.attemptNotVersionSeven(random)) { try AttemptID(random) }
    let id = UUID.v7()
    #expect(try AttemptID(id).ref == EntityRef(kind: JobSchema.attemptKind, key: EntityKey(uuid: id)))
  }

  @Test func shouldKeepTheFirstRequestWhenTwoDevicesRequestTheSameJob() async throws {
    let devices = try JobDevices()
    let key = try Self.key()
    for (store, replica) in zip(devices.both, ["first", "second"]) {
      let request = JSONValue.object(key.requestMembers.merging(["replica": .string(replica)]) { first, _ in first })
      try await devices.set(key.ref, ["request": request, "cancel": "none"], in: store)
    }
    try await devices.exchange()
    #expect(try await devices.agreed(key.ref)[field: "request"]?.value["replica"] == "first")
    for store in devices.both { #expect(try await store.read { transaction in try transaction.states(ofKind: JobSchema.jobKind).count } == 1) }
  }

  @Test func shouldNeverWithdrawACancelRequest() async throws {
    let devices = try JobDevices()
    let key = try Self.key()
    try await devices.set(key.ref, ["request": .object(key.requestMembers), "cancel": "none"], in: devices.first)
    try await devices.exchange()
    try await devices.set(key.ref, ["cancel": "requested"], in: devices.first)
    try await devices.set(key.ref, ["cancel": "none"], in: devices.second)
    try await devices.exchange()
    #expect(try await devices.agreed(key.ref)[field: "cancel"]?.value == "requested")
  }

  @Test(arguments: [
    (["running", "stood_down"], "stood_down"), (["succeeded", "failed"], "succeeded"), (["failed", "cancelled"], "cancelled"), (["cancelled", "failed"], "cancelled"),
    (["failed", "stood_down"], "stood_down"), (["stood_down", "failed"], "stood_down"), (["cancelled", "stood_down"], "cancelled"), (["succeeded", "cancelled"], "succeeded"),
    (["succeeded", "running"], "succeeded"),
  ])
  func shouldSettleConcurrentOutcomesOnTheHigherOne(_ outcomes: [String], _ settled: String) async throws {
    let devices = try JobDevices()
    let attempt = try Self.attempt()
    try await devices.set(attempt, ["start": ["replica": "first"], "outcome": "running"], in: devices.first)
    try await devices.exchange()
    for (store, outcome) in zip(devices.both, outcomes) { try await devices.set(attempt, ["outcome": .string(outcome)], in: store) }
    try await devices.exchange()
    #expect(try await devices.agreed(attempt)[field: "outcome"]?.value == .string(settled))
  }

  @Test(arguments: ["queued", "done", "Succeeded"])
  func shouldRefuseAnOutcomeOutsideTheOrder(_ outcome: String) async throws {
    let devices = try JobDevices()
    await #expect(throws: StoreError.self) { try await devices.set(try Self.attempt(), ["outcome": .string(outcome)], in: devices.first) }
  }

  @Test func shouldKeepTheFirstStartAndErrorAndTheLatestLeaseStepAndCalls() async throws {
    let devices = try JobDevices()
    let attempt = try Self.attempt()
    for (store, device) in zip(devices.both, ["first", "second"]) {
      let fields: [String: JSONValue] = [
        "start": ["replica": .string(device)], "error": ["code": .string(device)], "lease": ["expires": .string(device)], "step": ["name": .string(device)],
        "calls": [.string(device)],
      ]
      try await devices.set(attempt, fields, in: store)
    }
    try await devices.exchange()
    let record = try await devices.agreed(attempt)
    #expect(record[field: "start"]?.value == ["replica": "first"])
    #expect(record[field: "error"]?.value == ["code": "first"])
    #expect(record[field: "lease"]?.value == ["expires": "second"])
    #expect(record[field: "step"]?.value == ["name": "second"])
    #expect(record[field: "calls"]?.value == ["second"])
  }
}
