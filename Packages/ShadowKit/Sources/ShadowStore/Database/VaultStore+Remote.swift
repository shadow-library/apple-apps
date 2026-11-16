import Foundation
import GRDB
import ShadowCore

public struct RemoteApplyResult: Sendable, Equatable {
  public let touched: [EntityRef]
  public let applied: Int
  public let opaque: Int
  public let highestClock: HLCTimestamp?
}

private enum RemoteLine {
  case record(ChangeRecord)
  case opaque(Data)

  init(_ line: Data) {
    guard let json = try? CanonicalJSON.decode(line, mode: .canonical), let record = try? ChangeRecord(json: json) else {
      self = .opaque(line)
      return
    }
    self = .record(record)
  }

  var record: ChangeRecord? {
    guard case .record(let record) = self else { return nil }
    return record
  }
}

extension VaultStore {
  public func applyRemote(
    _ lines: [Data], notAfter limit: HLCTimestamp? = nil, also body: @Sendable (Database) throws -> Void = { _ in }
  ) async throws(StoreError) -> RemoteApplyResult {
    try await merge(lines, notAfter: limit, into: [.vault], also: body)
  }

  public func adoptRemote(
    _ lines: [Data], notAfter limit: HLCTimestamp? = nil, also body: @Sendable (Database) throws -> Void = { _ in }
  ) async throws(StoreError) -> RemoteApplyResult {
    try await merge(lines, notAfter: limit, into: StateScope.allCases, also: body)
  }

  private func merge(
    _ lines: [Data], notAfter limit: HLCTimestamp?, into scopes: [StateScope], also body: @Sendable (Database) throws -> Void
  ) async throws(StoreError) -> RemoteApplyResult {
    let parsed = lines.map(RemoteLine.init)
    let records = parsed.compactMap(\.record)
    let highest = records.map(\.clock).max()
    let touched = try await writing { db in
      let row = try KernelRow.load(db)
      if records.contains(where: { $0.clock.replica == row.replica }) { throw StoreError.replicaCollision(row.replica) }
      if let limit, let highest, highest > limit { throw StoreError.clockAhead(highest) }
      let routine = MergeRoutine(registry: self.registry)
      var touched = TouchedRefs()
      for line in parsed {
        switch line {
        case .record(let record):
          for scope in scopes {
            if try routine.apply(record, scope: scope, in: db) { touched.insert(record.ref, scope: scope) }
          }
        case .opaque(let bytes):
          for scope in scopes { try routine.keepOpaque(bytes, scope: scope, in: db) }
        }
      }
      if let highest { try KernelRow.observe(highest, ownReplica: row.replica, in: db) }
      let refs = try self.settlement.settle(touched, origin: .remote, in: db)
      try body(db)
      return refs
    }
    if let highest { observe(highest) }
    return RemoteApplyResult(touched: touched, applied: records.count, opaque: parsed.count - records.count, highestClock: highest)
  }
}
