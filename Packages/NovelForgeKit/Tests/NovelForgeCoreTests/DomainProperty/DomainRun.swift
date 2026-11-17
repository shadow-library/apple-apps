import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization

@testable import NovelForgeCore

/// What a domain operation does on the replica that runs it: one write transaction stamped with that replica's wall clock, or several calls on its store
/// (the app's async entry points such as `VaultStore.approveChapter`).
enum DomainStep: Sendable {
  case write(@Sendable (inout WriteTransaction, Date) throws -> Void)
  case store(@Sendable (VaultStore) async throws -> Void)
}

struct DomainOperation: Sendable {
  let name: String
  let weight: Int
  let make: @Sendable (inout SeededGenerator, DomainUniverse) -> DomainStep

  static func pick(from operations: [DomainOperation], _ generator: inout SeededGenerator) -> DomainOperation {
    var remaining = generator.int(in: 0...max(operations.map(\.weight).reduce(0, +) - 1, 0))
    for operation in operations {
      if remaining < operation.weight { return operation }
      remaining -= operation.weight
    }
    return operations[operations.count - 1]
  }
}

enum DomainRunFailure: Error, CustomStringConvertible {
  case unavailable(operation: String, error: String)
  case notARebuild(replica: Int, tables: [String])
  case faults(replica: Int, [String])
  case diverged(replica: Int, tables: [String])
  case invariants(replica: Int, [String])
  case unsettled
  case inOrder(String, String)

  var description: String {
    switch self {
    case .unavailable(let operation, let error): "\(operation) failed with an error that is not a refusal: \(error)"
    case .notARebuild(let replica, let tables): "replica \(replica): incremental tables differ from a rebuild in \(tables.joined(separator: ", "))"
    case .faults(let replica, let faults): "replica \(replica) recorded faults: \(faults.joined(separator: "; "))"
    case .diverged(let replica, let tables): "replica \(replica) differs from replica 0 in \(tables.joined(separator: ", "))"
    case .invariants(let replica, let violations): "replica \(replica) breaks \(violations.count) invariants:\n" + violations.joined(separator: "\n")
    case .unsettled: "a replica still has changes to receive after settling"
    case .inOrder(let order, let failure): "with \(order) delivery: \(failure)"
    }
  }
}

/// How often each operation ran and was refused, over every case of a run.
final class DomainTally: Sendable {
  struct Count: Sendable, Equatable {
    var done = 0
    var refusals: [String: Int] = [:]
  }

  private let counts = Mutex<[String: Count]>([:])

  func record(_ name: String, refusal: String? = nil) {
    counts.withLock { counts in
      if let refusal { counts[name, default: Count()].refusals[refusal, default: 0] += 1 } else { counts[name, default: Count()].done += 1 }
    }
  }

  var snapshot: [String: Count] { counts.withLock { $0 } }
}

enum DomainRefusal {
  /// The refusals an operation may meet in a healthy vault; a guard reporting stale or unreadable state is not one, since the run never faults.
  static func code(of error: any Error) -> String? {
    if let error = error as? StoreError {
      guard case .aborted(let cause) = error else { return nil }
      return code(of: cause)
    }
    if let error = error as? DomainError {
      switch error {
      case .store, .unreadable, .unreadableRecords, .lifecycleUnavailable, .planStateUnavailable, .revisionUnreadable, .versionUnreadable: return nil
      default: return error.code
      }
    }
    if let error = error as? NotebookError {
      switch error {
      case .store, .entryNotUnderstood: return nil
      default: return error.code
      }
    }
    return nil
  }
}

extension CausalReplicas {
  /// Runs one domain operation on replica `index`; a refusal writes nothing and is tallied, anything else fails the run.
  func perform(_ operation: DomainOperation, _ step: DomainStep, on index: Int, tally: DomainTally) async throws {
    do {
      switch step {
      case .write(let body):
        let now = store(index).wallClock()
        _ = try await write(index) { transaction in try body(&transaction, now) }
      case .store(let body):
        try await body(store(index))
        try await collect(index)
      }
      tally.record(operation.name)
    } catch {
      guard let code = DomainRefusal.code(of: error) else { throw DomainRunFailure.unavailable(operation: operation.name, error: String(describing: error)) }
      if case .store = step { try await collect(index) }
      tally.record(operation.name, refusal: code)
    }
  }

  /// Takes what was written on the store directly into the replica's stream: a write with no changes of its own hands every pending change to `write`, which
  /// stamps them with the replica's current dependencies.
  func collect(_ index: Int) async throws {
    _ = try await write(index) { _ in }
  }
}
