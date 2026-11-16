import Foundation
import ShadowCore
import ShadowTestSupport
import Synchronization

@testable import ShadowStore

final class ManualClock: Sendable {
  static let start = Date(timeIntervalSince1970: 1_700_000_000)

  private let date: Mutex<Date>

  init(_ date: Date = ManualClock.start) {
    self.date = Mutex(date)
  }

  var now: Date {
    date.withLock { $0 }
  }

  var millis: Int64 {
    Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
  }

  func set(_ newDate: Date) {
    date.withLock { $0 = newDate }
  }

  func advance(by seconds: TimeInterval) {
    date.withLock { $0 = $0.addingTimeInterval(seconds) }
  }

  var function: @Sendable () -> Date {
    { self.now }
  }
}

final class TemporaryDirectory {
  let url: URL

  init() {
    url = FileManager.default.temporaryDirectory.appending(path: "shadow-store-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  var storeURL: URL {
    url.appending(path: "vault.sqlite")
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

enum StoreFixture {
  static func open(_ registry: SchemaRegistry = Fixture.v1, at location: StoreLocation = .inMemory, clock: ManualClock = ManualClock()) throws -> VaultStore {
    try VaultStore.open(location, registry: registry, wallClock: clock.function)
  }

  static func logged(_ records: [ChangeRecord], from first: Int64 = 1) -> [LoggedChange] {
    records.enumerated().map { LoggedChange(sequence: first + Int64($0.offset), line: $0.element.canonicalBytes()) }
  }
}

extension VaultStore {
  func apply(_ records: [ChangeRecord], scope: StateScope = .vault) async throws {
    try await write { transaction in
      for record in records { try transaction.apply(record, scope: scope) }
    }
  }

  func keepOpaque(_ lines: [Data], scope: StateScope = .vault) async throws {
    try await write { transaction in
      for line in lines { try transaction.keepOpaque(line, scope: scope) }
    }
  }

  var allPending: [LoggedChange] {
    get async throws { try await pendingChanges(limit: Int.max) }
  }
}

enum LocalParent: Sendable {
  case head
  case none
  case known(Int)
}

enum LocalOperation: Sendable {
  case set(EntityRef, [String: JSONValue])
  case purge(EntityRef)
  case append(EntityRef, [String: JSONValue])
  case revise(EntityRef, JSONValue, parent: LocalParent, head: Bool, marks: [String])
  case reassert(EntityRef, pick: Int, head: Bool, marks: [String])

  static let notes = Fixture.noteKeys.map { EntityRef(kind: Fixture.note, key: $0) }
  static let messages = Fixture.messageKeys.map { EntityRef(kind: Fixture.message, key: $0) }
  static let revisioned = Fixture.draftKeys.flatMap { [EntityRef(kind: Fixture.draft, key: $0), EntityRef(kind: Fixture.outline, key: $0)] }
  static let tags = [EntityRef(kind: Fixture.tag, key: Fixture.key("t1"))]

  static func random(_ generator: inout SeededGenerator) -> LocalOperation {
    switch generator.int(in: 0...99) {
    case 0..<30:
      var fields = [String: JSONValue]()
      if generator.chance(0.6) { fields["title"] = generator.pick(from: Fixture.values) }
      if generator.chance(0.5) { fields["status"] = .string(generator.pick(from: Fixture.extendedStatusOrder)) }
      if generator.chance(0.3) { fields["origin"] = generator.pick(from: Fixture.values) }
      if generator.chance(0.3) { fields["pinned"] = generator.pick(from: Fixture.values) }
      if fields.isEmpty { fields["title"] = generator.pick(from: Fixture.values) }
      return .set(generator.pick(from: notes), fields)
    case 30..<38:
      return .set(generator.pick(from: revisioned.filter { $0.kind == Fixture.draft }), ["title": generator.pick(from: Fixture.values)])
    case 38..<42:
      return .set(generator.pick(from: tags), ["label": generator.pick(from: Fixture.values)])
    case 42..<55:
      return .append(generator.pick(from: messages), ["text": generator.pick(from: Fixture.values), "n": .int(Int64(generator.int(in: 0...2)))])
    case 55..<75:
      let ref = generator.pick(from: revisioned)
      let parent: LocalParent = generator.chance(0.5) ? .head : generator.chance(0.5) ? .none : .known(generator.int(in: 0...20))
      return .revise(ref, generator.pick(from: Fixture.values), parent: parent, head: generator.chance(0.6), marks: marks(ref, &generator))
    case 75..<93:
      let ref = generator.pick(from: revisioned)
      return .reassert(ref, pick: generator.int(in: 0...20), head: generator.chance(0.6), marks: marks(ref, &generator))
    default:
      return .purge(generator.pick(from: notes + messages + revisioned + tags))
    }
  }

  private static func marks(_ ref: EntityRef, _ generator: inout SeededGenerator) -> [String] {
    guard ref.kind == Fixture.draft else { return [] }
    return generator.pick(from: [[], [], ["approved"], ["reviewed"], ["approved", "reviewed"]])
  }

  /// Nil when the store refuses the operation for a reason the random script cannot foresee.
  func run(_ transaction: inout WriteTransaction, known: inout [EntityRef: [String]]) throws -> ChangeRecord? {
    do {
      switch self {
      case .set(let ref, let fields):
        return try transaction.set(ref, fields)
      case .purge(let ref):
        return try transaction.purge(ref)
      case .append(let ref, let item):
        return try transaction.append(ref, item: item)
      case .revise(let ref, let body, let parent, let head, let marks):
        let resolved: RevisionParent
        switch parent {
        case .head: resolved = .head
        case .none: resolved = .none
        case .known(let pick): resolved = known[ref].flatMap { $0.isEmpty ? nil : .revision($0[pick % $0.count]) } ?? .none
        }
        let (record, revision) = try transaction.revise(ref, body: body, parent: resolved, head: head, marks: marks)
        known[ref, default: []].append(revision)
        return record
      case .reassert(let ref, let pick, let head, let marks):
        guard let ids = known[ref], !ids.isEmpty else { return nil }
        return try transaction.reassert(ref, revision: ids[pick % ids.count], head: head, marks: marks)
      }
    } catch StoreError.entityPurged {
      return nil
    } catch StoreError.unknownRevision {
      return nil
    } catch StoreError.invalidChange(let reason) where reason.hasSuffix("already holds an item") {
      return nil
    }
  }
}

func runLocal(_ operations: [LocalOperation], in store: VaultStore, known: [EntityRef: [String]]) async throws -> (records: [ChangeRecord], known: [EntityRef: [String]]) {
  try await store.write { transaction in
    var known = known
    var records = [ChangeRecord]()
    for operation in operations { if let record = try operation.run(&transaction, known: &known) { records.append(record) } }
    return (records, known)
  }
}
