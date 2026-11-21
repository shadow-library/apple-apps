import Foundation
import ShadowCore

/// Sealed with a ring key under `VaultPath.moveNotice`, so only a holder of the vault's keys can write one and it opens for no other vault or path.
public struct VaultMoveNotice: Sendable, Equatable {
  /// The replica that wrote the notice; it was retired by the move, so a notice whose writer a reader knows as retired is a replay.
  public let from: ReplicaID
  public let to: ReplicaID
  public let base: BaseReference
  /// The highest clock of each stamping replica in the moved base; a change stamped above it, or by a replica it does not name, may be missing there.
  public let frontier: [ReplicaID: HLCTimestamp]
  /// The new location's non-secret settings, in the runtime's own encoding.
  public let target: [String: JSONValue]
  public let movedMillis: Int64

  public init(from: ReplicaID, to: ReplicaID, base: BaseReference, frontier: [ReplicaID: HLCTimestamp], target: [String: JSONValue], movedMillis: Int64) {
    self.from = from
    self.to = to
    self.base = base
    self.frontier = frontier
    self.target = target
    self.movedMillis = movedMillis
  }
}

public enum VaultMoveNoticeCodec {
  public static let maximumBytes = 1024 * 1024
  static let format: Int64 = 1
  private static let kind = "moved"
  private static let members: Set<String> = ["base", "format", "from", "frontier", "kind", "moved", "target", "to"]

  public static func seal(_ notice: VaultMoveNotice, vault: VaultID, with key: VaultKey) throws(ReplicaFileError) -> Data {
    let payload = CanonicalJSON.encode(
      .object([
        "base": .object(["parts": .int(Int64(notice.base.parts)), "tag": .string(notice.base.tag.description), "upto": .int(notice.base.upTo)]),
        "format": .int(format),
        "from": .string(notice.from.description),
        "frontier": .object(Dictionary(uniqueKeysWithValues: notice.frontier.map { ($0.key.description, .string($0.value.description)) })),
        "kind": .string(kind),
        "moved": .int(notice.movedMillis),
        "target": .object(notice.target),
        "to": .string(notice.to.description),
      ]))
    guard payload.count <= maximumBytes else { throw .tooLarge }
    do {
      return try VaultFile.seal(payload, path: VaultPath.moveNotice.rawValue, vault: vault, key: key)
    } catch {
      throw .file(error)
    }
  }

  public static func open(_ data: Data, vault: VaultID, keys: (KeyID) -> VaultKey?) throws(ReplicaFileError) -> VaultMoveNotice {
    guard data.count <= 2 * maximumBytes else { throw .tooLarge }
    let payload: Data
    do {
      payload = try VaultFile.open(data, path: VaultPath.moveNotice.rawValue, vault: vault, keys: keys)
    } catch {
      throw .file(error)
    }
    guard payload.count <= maximumBytes else { throw .tooLarge }
    let members = try ReplicaJSON.object(payload)
    try ReplicaJSON.requireFormat(members, current: format)
    guard Set(members.keys) == Self.members, try ReplicaJSON.string(members, "kind") == kind else { throw .malformed("move notice members differ") }
    let from = try ReplicaJSON.replica(try ReplicaJSON.string(members, "from"), name: "from")
    let to = try ReplicaJSON.replica(try ReplicaJSON.string(members, "to"), name: "to")
    guard from != to else { throw .malformed("a move notice names one replica twice") }
    guard case .object(let target)? = members["target"] else { throw .malformed("target is not an object") }
    return VaultMoveNotice(
      from: from, to: to, base: try base(members["base"]), frontier: try frontier(members["frontier"]), target: target, movedMillis: try ReplicaJSON.int(members, "moved"))
  }

  private static func base(_ value: JSONValue?) throws(ReplicaFileError) -> BaseReference {
    guard case .object(let members)? = value, let tag = ContentTag(try ReplicaJSON.string(members, "tag")) else { throw .malformed("base is not a base reference") }
    let upTo = try ReplicaJSON.int(members, "upto", in: 0...VaultPath.maximumSequence)
    let parts = try ReplicaJSON.int(members, "parts", in: 1...Int64(VaultPath.maximumParts))
    guard let base = BaseReference(upTo: upTo, tag: tag, parts: Int(parts)) else { throw .malformed("base is not a base reference") }
    return base
  }

  private static func frontier(_ value: JSONValue?) throws(ReplicaFileError) -> [ReplicaID: HLCTimestamp] {
    guard case .object(let entries)? = value else { throw .malformed("frontier is not an object") }
    var frontier: [ReplicaID: HLCTimestamp] = [:]
    for (text, entry) in entries {
      let replica = try ReplicaJSON.replica(text, name: "frontier")
      guard case .string(let clockText) = entry, let clock = HLCTimestamp(clockText), clock.replica == replica else { throw .malformed("a frontier clock is malformed") }
      frontier[replica] = clock
    }
    return frontier
  }
}
