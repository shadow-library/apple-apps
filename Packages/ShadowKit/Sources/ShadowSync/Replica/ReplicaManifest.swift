import Foundation
import ShadowCore

public struct BaseReference: Sendable, Equatable {
  public let upTo: Int64
  public let tag: ContentTag
  public let parts: Int

  public init?(upTo: Int64, tag: ContentTag, parts: Int) {
    guard (0...VaultPath.maximumSequence).contains(upTo), (1...VaultPath.maximumParts).contains(parts) else { return nil }
    self.upTo = upTo
    self.tag = tag
    self.parts = parts
  }
}

public struct ReplicaManifest: Sendable, Equatable {
  public var replica: ReplicaID
  public var deviceName: String
  public var platform: String
  public var appVersion: String
  public var schema: Int
  public var head: StreamPoint?
  public var base: BaseReference?
  public var applied: [ReplicaID: StreamPoint]
  public var updatedMillis: Int64

  public init(
    replica: ReplicaID,
    deviceName: String,
    platform: String,
    appVersion: String,
    schema: Int,
    head: StreamPoint?,
    base: BaseReference?,
    applied: [ReplicaID: StreamPoint],
    updatedMillis: Int64
  ) {
    self.replica = replica
    self.deviceName = deviceName
    self.platform = platform
    self.appVersion = appVersion
    self.schema = schema
    self.head = head
    self.base = base
    self.applied = applied
    self.updatedMillis = updatedMillis
  }
}

public enum ReplicaManifestCodec {
  public static let maximumBytes = 1024 * 1024
  static let maximumStringBytes = 256
  static let format: Int64 = 1

  public static func payload(of manifest: ReplicaManifest) -> Data {
    CanonicalJSON.encode(
      .object([
        "app": .string(clamped(manifest.appVersion)),
        "applied": .object(Dictionary(uniqueKeysWithValues: manifest.applied.map { ($0.key.description, CodecFrame.pointValue($0.value)) })),
        "base": manifest.base.map(baseValue) ?? .null,
        "device": .string(clamped(manifest.deviceName)),
        "format": .int(format),
        "head": manifest.head.map(CodecFrame.pointValue) ?? .null,
        "platform": .string(clamped(manifest.platform)),
        "replica": .string(manifest.replica.description),
        "schema": .int(Int64(manifest.schema)),
        "updated": .int(manifest.updatedMillis),
      ])
    )
  }

  public static func seal(_ manifest: ReplicaManifest, vault: VaultID, with key: VaultKey) throws(ReplicaFileError) -> (key: ObjectKey, data: Data) {
    let manifest = clamped(manifest)
    try validate(manifest)
    let payload = payload(of: manifest)
    guard payload.count <= maximumBytes else { throw .tooLarge }
    let objectKey = VaultPath.manifest(manifest.replica)
    do {
      return (key: objectKey, data: try VaultFile.seal(payload, path: objectKey.rawValue, vault: vault, key: key))
    } catch {
      throw .file(error)
    }
  }

  public static func open(_ data: Data, at key: ObjectKey, vault: VaultID, keys: (KeyID) -> VaultKey?) throws(ReplicaFileError) -> ReplicaManifest {
    guard case .manifest(let pathReplica) = VaultPath.classify(key) else { throw .pathMismatch }
    let payload: Data
    do {
      payload = try VaultFile.open(data, path: key.rawValue, vault: vault, keys: keys)
    } catch {
      throw .file(error)
    }
    guard payload.count <= maximumBytes else { throw .tooLarge }
    let members = try ReplicaJSON.object(payload)
    try ReplicaJSON.requireFormat(members, current: format)
    let replica = try ReplicaJSON.replica(try ReplicaJSON.string(members, "replica"), name: "replica")
    guard replica == pathReplica else { throw .pathMismatch }
    let manifest = ReplicaManifest(
      replica: replica,
      deviceName: try ReplicaJSON.string(members, "device"),
      platform: try ReplicaJSON.string(members, "platform"),
      appVersion: try ReplicaJSON.string(members, "app"),
      schema: Int(clamping: try ReplicaJSON.int(members, "schema", in: Int64.min...Int64.max)),
      head: try optionalPoint(members["head"], name: "head"),
      base: try optionalBase(members["base"]),
      applied: try appliedPoints(members["applied"]),
      updatedMillis: try ReplicaJSON.int(members, "updated", in: Int64.min...Int64.max)
    )
    try validate(manifest)
    return manifest
  }

  static func validate(_ manifest: ReplicaManifest) throws(ReplicaFileError) {
    guard (0...Int(Int32.max)).contains(manifest.schema) else { throw .malformed("schema is out of range") }
    guard manifest.updatedMillis >= 0 else { throw .malformed("updated is negative") }
    guard manifest.head.map(isOnStream) ?? true, manifest.applied.values.allSatisfy(isOnStream) else { throw .malformed("a stream point is out of range") }
    guard manifest.applied[manifest.replica] == nil else { throw .malformed("applied names the replica itself") }
    let strings = [manifest.deviceName, manifest.platform, manifest.appVersion]
    guard strings.allSatisfy({ $0.utf8.count <= maximumStringBytes }) else { throw .malformed("a string exceeds \(maximumStringBytes) bytes") }
  }

  static func clamped(_ manifest: ReplicaManifest) -> ReplicaManifest {
    var result = manifest
    result.deviceName = clamped(manifest.deviceName)
    result.platform = clamped(manifest.platform)
    result.appVersion = clamped(manifest.appVersion)
    return result
  }

  private static func isOnStream(_ point: StreamPoint) -> Bool {
    (1...VaultPath.maximumSequence).contains(point.last)
  }

  private static func clamped(_ text: String) -> String {
    guard text.utf8.count > maximumStringBytes else { return text }
    var result = ""
    var used = 0
    for character in text {
      let size = character.utf8.count
      guard used + size <= maximumStringBytes else { break }
      result.append(character)
      used += size
    }
    return result
  }

  private static func baseValue(_ base: BaseReference) -> JSONValue {
    .object(["parts": .int(Int64(base.parts)), "tag": .string(base.tag.description), "upto": .int(base.upTo)])
  }

  private static func optionalPoint(_ value: JSONValue?, name: String) throws(ReplicaFileError) -> StreamPoint? {
    guard let value else { throw .malformed("\(name) is missing") }
    if value.isNull { return nil }
    return try point(value, name: name)
  }

  private static func point(_ value: JSONValue, name: String) throws(ReplicaFileError) -> StreamPoint {
    guard case .object(let members) = value else { throw .malformed("\(name) is not a stream point") }
    let last = try ReplicaJSON.int(members, "last", in: Int64.min...Int64.max)
    guard let tag = ContentTag(try ReplicaJSON.string(members, "tag")) else { throw .malformed("\(name) has an invalid tag") }
    return StreamPoint(last: last, tag: tag)
  }

  private static func appliedPoints(_ value: JSONValue?) throws(ReplicaFileError) -> [ReplicaID: StreamPoint] {
    guard case .object(let entries)? = value else { throw .malformed("applied is not an object") }
    var points: [ReplicaID: StreamPoint] = [:]
    for (text, entry) in entries { points[try ReplicaJSON.replica(text, name: "applied")] = try point(entry, name: "applied") }
    return points
  }

  private static func optionalBase(_ value: JSONValue?) throws(ReplicaFileError) -> BaseReference? {
    guard let value else { throw .malformed("base is missing") }
    if value.isNull { return nil }
    guard case .object(let members) = value, let tag = ContentTag(try ReplicaJSON.string(members, "tag")) else { throw .malformed("base is not a base reference") }
    let upTo = try ReplicaJSON.int(members, "upto", in: 0...VaultPath.maximumSequence)
    let parts = try ReplicaJSON.int(members, "parts", in: 1...Int64(VaultPath.maximumParts))
    guard let base = BaseReference(upTo: upTo, tag: tag, parts: Int(parts)) else { throw .malformed("base is not a base reference") }
    return base
  }
}
