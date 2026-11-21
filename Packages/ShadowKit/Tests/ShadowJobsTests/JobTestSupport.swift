import Foundation
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import ShadowJobs

enum JobFixture {
  static let outputKind = makeKind("jobs_test_output")
  static let registry = SchemaRegistry(
    version: 1, entities: JobSchema.entities + JobSchema.workerEntities + [EntitySchema(kind: outputKind, shape: .appended, syncClass: .general)])
  static let novel = "6f0c4d1e-0000-4000-8000-000000000001"
  static let epoch: Int64 = 1_700_000_000_000

  static func key(target: String = "chapter:3", run: Int = 1) throws -> JobKey {
    try JobKey(scope: novel, kind: "generate", target: target, fingerprint: "f0", run: run)
  }

  static func instant(_ seconds: Int64, _ source: AttemptClockSource = .trusted) -> LeaseInstant {
    LeaseInstant(millis: epoch + seconds * 1000, source: source)
  }

  static func replica(_ index: Int) -> ReplicaID {
    ReplicaID(UUID(uuidString: String(format: "00000000-0000-7000-8000-%012d", index)) ?? UUID())
  }

  static func attemptID(_ seconds: Int64, _ index: Int = 0) throws -> AttemptID {
    var generator = Fixed(index)
    return try AttemptID(UUID.v7(at: instant(seconds).date, using: &generator))
  }

  static func request(_ key: JobKey, replica: ReplicaID, payload: JSONValue = ["chapter": 3]) -> JobRequest {
    JobRequest(key: key, payload: payload, replica: replica)
  }

  static func start(_ key: JobKey, replica: ReplicaID, at seconds: Int64, byHand: Bool = false) -> AttemptStart {
    AttemptStart(job: key.ref, replica: replica, started: instant(seconds), byHand: byHand, pinned: ["plan": "p1"])
  }

  static func open(clock: DeviceClock = DeviceClock()) throws -> VaultStore {
    try VaultStore.open(.inMemory, registry: registry, wallClock: clock.function)
  }

  static func outputs(in store: VaultStore) async throws -> [String: String] {
    try await store.read { transaction in
      var texts: [String: String] = [:]
      for (_, state) in try transaction.states(ofKind: outputKind) {
        guard case .appended(let item) = state, let step = item.item["step"]?.stringValue, let text = item.item["text"]?.stringValue else { continue }
        texts[step] = text
      }
      return texts
    }
  }

  /// How many changes each output ref received, over the whole unsent log.
  static func outputWrites(in store: VaultStore) async throws -> [EntityRef: Int] {
    var counts: [EntityRef: Int] = [:]
    for change in try await store.pendingChanges(limit: Int.max) {
      let record = try ChangeRecord(json: try CanonicalJSON.decode(change.line))
      if record.entity == outputKind { counts[record.ref, default: 0] += 1 }
    }
    return counts
  }

  static func attempt(_ id: AttemptID, in store: VaultStore) async throws -> AttemptRecord {
    try #require(try await store.read { transaction in try AttemptRecords.read(id, in: transaction) }.record)
  }

  static func snapshot(_ ref: EntityRef, in store: VaultStore) async throws -> JobSnapshot {
    try #require(try await store.read { transaction in try JobSnapshot.load(ref, in: transaction) })
  }

  static func localRuns(in store: VaultStore) async throws -> [LocalRun] {
    let replica = store.replica
    return try await store.read { transaction in try JobsLocal.runs(of: replica, in: transaction.database) }
  }

  static func exchange(_ stores: [VaultStore]) async throws {
    let lines = try await stores.mapInOrder { store in try await store.pendingChanges(limit: Int.max).map(\.line) }
    for (reader, store) in stores.enumerated() {
      for (writer, written) in lines.enumerated() where writer != reader { _ = try await store.applyRemote(written) }
    }
  }

  private static func makeKind(_ name: String) -> EntityKind {
    guard let kind = EntityKind(name) else { preconditionFailure("\(name) is a valid entity kind") }
    return kind
  }
}

struct Fixed: RandomNumberGenerator {
  private var value: UInt64

  init(_ value: Int) {
    self.value = UInt64(value)
  }

  mutating func next() -> UInt64 {
    value &+= 0x9E37_79B9_7F4A_7C15
    return value
  }
}

final class DeviceClock: Sendable {
  private let date = Mutex(Date(timeIntervalSince1970: Double(JobFixture.epoch) / 1000))

  var function: @Sendable () -> Date { { self.date.withLock { $0 } } }

  var now: Date { date.withLock { $0 } }

  func advance(_ seconds: TimeInterval) {
    date.withLock { $0 = $0.addingTimeInterval(seconds) }
  }
}

struct FixtureError: Error, CustomStringConvertible {
  let description: String
}

extension Array {
  func mapInOrder<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
    var mapped = [T]()
    for element in self { mapped.append(try await transform(element)) }
    return mapped
  }
}

func eventually(_ what: String, timeout: Duration = .seconds(120), _ condition: @Sendable () async throws -> Bool) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if try await condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw FixtureError(description: "timed out waiting until \(what)")
}

enum TestTimeLimit {
  static let quick = TimeLimitTrait.timeLimit(.minutes(5))
}
