import Foundation
import GRDB
import ShadowCore
import ShadowStore

public struct ReplicaDevice: Sendable, Equatable {
  public var name: String
  public var platform: String
  public var appVersion: String

  public init(name: String, platform: String, appVersion: String) {
    self.name = name
    self.platform = platform
    self.appVersion = appVersion
  }
}

public enum ReplicaBootstrap: Sendable, Equatable {
  case alreadyRunning
  case claimed(previous: ReplicaID?)
  case reminted(from: ReplicaID, reason: RemintReason)
}

enum ReplicaLifecycleStep: Sendable, Equatable, CaseIterable {
  case claimMinted
  case claimMarked
  case remintTokenRecorded
  case remintTokenClaimed
  case remintPrepared
  case remintMoved
  case remintDeclared
  case remintMarked
}

/// Not reentrant: the caller runs one lifecycle operation at a time per database.
public struct ReplicaLifecycle: Sendable {
  private let store: VaultStore
  private let vault: VaultID
  private let marker: DeviceMarker
  private let device: ReplicaDevice
  private let wallClock: @Sendable () -> Date
  private let makeReplicaID: @Sendable () -> ReplicaID
  private let checkpoint: @Sendable (ReplicaLifecycleStep) throws(ReplicaLifecycleError) -> Void

  public init(
    store: VaultStore,
    vault: VaultID,
    marker: DeviceMarker,
    device: ReplicaDevice,
    wallClock: @escaping @Sendable () -> Date = { Date() },
    makeReplicaID: @escaping @Sendable () -> ReplicaID = { ReplicaID(UUID.v7()) }
  ) {
    self.init(store: store, vault: vault, marker: marker, device: device, wallClock: wallClock, makeReplicaID: makeReplicaID) { _ throws(ReplicaLifecycleError) in }
  }

  init(
    store: VaultStore,
    vault: VaultID,
    marker: DeviceMarker,
    device: ReplicaDevice,
    wallClock: @escaping @Sendable () -> Date,
    makeReplicaID: @escaping @Sendable () -> ReplicaID,
    checkpoint: @escaping @Sendable (ReplicaLifecycleStep) throws(ReplicaLifecycleError) -> Void
  ) {
    self.store = store
    self.vault = vault
    self.marker = marker
    self.device = device
    self.wallClock = wallClock
    self.makeReplicaID = makeReplicaID
    self.checkpoint = checkpoint
  }

  public static var migrations: [StoreMigration] {
    [ReplicaHistory.migration, ReplicaLifecyclePhase.migration, ReplicaHistory.completionMigration]
  }

  public func bootstrap() async throws(ReplicaLifecycleError) -> ReplicaBootstrap {
    let phase = try await currentPhase()
    let replica = store.replica
    let status = marker.status(vault: vault, replica: replica)
    guard status != .unreadable else { throw .markerUnavailable }
    switch phase {
    case .fresh:
      return try await claim(previous: Self.previous(status), from: phase)
    case .claiming(_, let previous) where status == .matches:
      try await finishClaim()
      return .claimed(previous: previous)
    case .claiming:
      return try await claim(previous: Self.previous(status), from: phase)
    case .claimed where status == .matches:
      try await write { transaction in
        try ReplicaDirectory.declareActive(replica, name: device.name, platform: device.platform, createdMillis: millis, in: &transaction)
      }
      return .alreadyRunning
    case .claimed:
      let reason = Self.copiedReason(status)
      _ = try await move(reason: reason, mode: .keepState, from: phase)
      return .reminted(from: replica, reason: reason)
    case .preparing(_, let retiring, _, let reason):
      _ = try await move(reason: reason, mode: .keepState, from: phase)
      return .reminted(from: retiring, reason: reason)
    case .moving(_, let retiring, let token, let reason) where status == .matches || status == .other(token):
      try await finishMove(retiring: retiring)
      return .reminted(from: retiring, reason: reason)
    case .moving(_, let retiring, _, _):
      let reason = Self.copiedReason(status)
      _ = try await move(reason: reason, mode: .keepState, from: phase)
      return .reminted(from: retiring, reason: reason)
    }
  }

  public func selfCheck(listing: [ObjectKey]) async throws(ReplicaLifecycleError) -> ReplicaSelfCheckVerdict {
    let replica = store.replica
    let (phase, retired, history) = try await read { transaction in
      (
        try ReplicaLifecyclePhase.load(transaction.database), ReplicaDirectory.isRetired(try transaction.state(of: SyncKernelSchema.replicaRef(replica))),
        try ReplicaHistory.uploads(of: replica, in: transaction.database)
      )
    }
    try requireMatching(phase, replica)
    guard case .claimed = phase else { throw .bootstrapRequired }
    let status = marker.status(vault: vault, replica: replica)
    return ReplicaSelfCheck.evaluate(ReplicaSelfCheckInput(replica: replica, marker: status, isRetired: retired, listed: listing, history: history))
  }

  /// `also` runs in the transaction that moves the store to the new id.
  public func remint(
    reason: RemintReason, mode: RemintMode = .keepState, also: @escaping @Sendable (Database) throws -> Void = { _ in }
  ) async throws(ReplicaLifecycleError) -> ReplicaID {
    let phase = try await currentPhase()
    guard case .claimed = phase else { throw .bootstrapRequired }
    return try await move(reason: reason, mode: mode, from: phase, also: also)
  }

  public func retire(_ other: ReplicaID, successor: ReplicaID? = nil) async throws(ReplicaLifecycleError) {
    guard other != store.replica else { throw .retiringCurrentReplica(other) }
    try await write { transaction in try ReplicaDirectory.retire(other, successor: successor, in: &transaction) }
  }

  public func directory() async throws(ReplicaLifecycleError) -> ReplicaDirectory {
    try await read { transaction in try ReplicaDirectory.read(in: transaction) }
  }

  public func manifest(applied: [ReplicaID: StreamPoint]) async throws(ReplicaLifecycleError) -> ReplicaManifest {
    let replica = store.replica
    let (head, base) = try await read { transaction in
      (try ReplicaHistory.head(of: replica, in: transaction.database), try ReplicaHistory.currentBase(of: replica, in: transaction.database))
    }
    return ReplicaManifest(
      replica: replica, deviceName: device.name, platform: device.platform, appVersion: device.appVersion, schema: store.registry.version, head: head, base: base,
      applied: applied.filter { $0.key != replica }, updatedMillis: millis)
  }

  private func currentPhase() async throws(ReplicaLifecycleError) -> ReplicaLifecyclePhase {
    let phase = try await read { try ReplicaLifecyclePhase.load($0.database) }
    try requireMatching(phase, store.replica)
    return phase
  }

  private func requireMatching(_ phase: ReplicaLifecyclePhase, _ replica: ReplicaID) throws(ReplicaLifecycleError) {
    guard let expected = phase.replica, expected != replica else { return }
    throw .corruptState("the lifecycle belongs to replica \(expected) but the store writes as \(replica)")
  }

  /// The id a replica syncs under is minted here, never inherited from the file, so a database copied before its claim finishes cannot share an id.
  private func claim(previous: ReplicaID?, from phase: ReplicaLifecyclePhase) async throws(ReplicaLifecycleError) -> ReplicaBootstrap {
    let replica = try mint(avoiding: [store.replica])
    try await transfer(to: replica, mode: .keepState, expecting: phase, recording: .claiming(replica: replica, previous: previous))
    try checkpoint(.claimMinted)
    try claimMarker(replica)
    try checkpoint(.claimMarked)
    try await finishClaim()
    return .claimed(previous: previous)
  }

  private func finishClaim() async throws(ReplicaLifecycleError) {
    let replica = store.replica
    try await write { transaction in
      try ReplicaDirectory.declareActive(replica, name: device.name, platform: device.platform, createdMillis: millis, in: &transaction)
      try ReplicaLifecyclePhase.claimed(replica).save(transaction.database)
    }
  }

  private func move(
    reason: RemintReason, mode: RemintMode, from start: ReplicaLifecyclePhase, also: @escaping @Sendable (Database) throws -> Void = { _ in }
  ) async throws(ReplicaLifecycleError) -> ReplicaID {
    let current = store.replica
    let retiring: ReplicaID
    switch start {
    case .preparing(_, let from, _, _), .moving(_, let from, _, _): retiring = from
    case .fresh, .claiming, .claimed: retiring = current
    }
    let status = marker.status(vault: vault, replica: current)
    guard status != .unreadable else { throw .markerUnavailable }
    let replica = try mint(avoiding: [current, retiring])
    var phase = start
    let token: ReplicaID
    if status == .matches {
      token = current
    } else {
      let preparing = ReplicaLifecyclePhase.preparing(replica: current, retiring: retiring, token: replica, reason: reason)
      try await write { transaction in
        guard try ReplicaLifecyclePhase.load(transaction.database) == start else { throw ReplicaLifecycleError.concurrentChange }
        try preparing.save(transaction.database)
      }
      phase = preparing
      try checkpoint(.remintTokenRecorded)
      try claimMarker(replica)
      try checkpoint(.remintTokenClaimed)
      token = replica
    }
    try checkpoint(.remintPrepared)
    try await transfer(to: replica, mode: mode, expecting: phase, recording: .moving(replica: replica, retiring: retiring, token: token, reason: reason), also: also)
    try checkpoint(.remintMoved)
    try await finishMove(retiring: retiring)
    return replica
  }

  private func finishMove(retiring: ReplicaID) async throws(ReplicaLifecycleError) {
    let replica = store.replica
    try await write { transaction in
      try ReplicaDirectory.retire(retiring, successor: replica, in: &transaction)
      try ReplicaDirectory.declareActive(replica, name: device.name, platform: device.platform, createdMillis: millis, in: &transaction)
    }
    try checkpoint(.remintDeclared)
    try claimMarker(replica)
    try checkpoint(.remintMarked)
    try await write { transaction in try ReplicaLifecyclePhase.claimed(replica).save(transaction.database) }
  }

  private func transfer(
    to replica: ReplicaID,
    mode: RemintMode,
    expecting phase: ReplicaLifecyclePhase,
    recording next: ReplicaLifecyclePhase,
    also: @escaping @Sendable (Database) throws -> Void = { _ in }
  ) async throws(ReplicaLifecycleError) {
    do {
      try await store.remint(to: replica, mode: mode) { db in
        guard try ReplicaLifecyclePhase.load(db) == phase else { throw ReplicaLifecycleError.concurrentChange }
        try next.save(db)
        try also(db)
      }
    } catch {
      throw ReplicaLifecycleError(converting: error)
    }
  }

  private func mint(avoiding used: [ReplicaID]) throws(ReplicaLifecycleError) -> ReplicaID {
    let replica = makeReplicaID()
    guard !used.contains(replica) else { throw .replicaReused(replica) }
    return replica
  }

  private func claimMarker(_ replica: ReplicaID) throws(ReplicaLifecycleError) {
    do {
      try marker.claim(vault: vault, replica: replica)
    } catch {
      throw .marker(error)
    }
  }

  private var millis: Int64 {
    max(0, Int64((wallClock().timeIntervalSince1970 * 1_000).rounded(.down)))
  }

  private static func previous(_ status: DeviceMarkerStatus) -> ReplicaID? {
    guard case .other(let replica) = status else { return nil }
    return replica
  }

  private static func copiedReason(_ status: DeviceMarkerStatus) -> RemintReason {
    guard case .other(let replica) = status else { return .markerMissing }
    return .markerNamesOther(replica)
  }

  private func read<T: Sendable>(_ body: @Sendable (ReadTransaction) throws -> T) async throws(ReplicaLifecycleError) -> T {
    do {
      return try await store.read(body)
    } catch {
      throw ReplicaLifecycleError(converting: error)
    }
  }

  private func write<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws -> T) async throws(ReplicaLifecycleError) -> T {
    do {
      return try await store.write(body)
    } catch {
      throw ReplicaLifecycleError(converting: error)
    }
  }
}
