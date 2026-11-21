import Foundation
import ShadowCore

public enum SyncFileKind: String, Sendable, Codable {
  case segment
  case base
}

/// A base is identified by its `upTo` and tag, carried in `point`.
public struct SyncFileID: Sendable, Hashable {
  public let replica: ReplicaID
  public let kind: SyncFileKind
  public let point: StreamPoint

  public init(replica: ReplicaID, kind: SyncFileKind, point: StreamPoint) {
    self.replica = replica
    self.kind = kind
    self.point = point
  }
}

public enum SyncHoldReason: Sendable, Equatable {
  case missingKey(KeyID)
  case unauthenticated
  case malformed
  case clockAhead
  case waitingForPredecessor
  case waitingForDependency(ReplicaID)
  case incompleteBase(missing: [Int])
  case rejected
  /// Written in a format this app version cannot read; fetched again only by a new engine instance, never rejected.
  case unsupported
  /// Storage could not deliver this one object; tried again on the next call.
  case unavailable
}

public struct SyncDownloadOutcome: Sendable, Equatable {
  public let applied: [SyncFileID]
  public let held: [SyncFileID: SyncHoldReason]
  /// Read from unauthenticated file headers: the storage provider can name any key id and any replica here.
  public let missingKeys: [KeyID: Set<ReplicaID>]
  public let reminted: Bool
  /// The device marker could not be read to re-mint, so the call stopped early; `applied` holds what was applied before.
  public let postponed: Bool
  /// The vault moved elsewhere: from now on this replica only downloads here and continues as a new replica at the notice's location.
  public let moved: VaultMoveNotice?

  public init(
    applied: [SyncFileID], held: [SyncFileID: SyncHoldReason], missingKeys: [KeyID: Set<ReplicaID>], reminted: Bool, postponed: Bool = false, moved: VaultMoveNotice? = nil
  ) {
    self.applied = applied
    self.held = held
    self.missingKeys = missingKeys
    self.reminted = reminted
    self.postponed = postponed
    self.moved = moved
  }
}

enum SyncDownloadStep: Sendable, Equatable, CaseIterable {
  case applied
}
