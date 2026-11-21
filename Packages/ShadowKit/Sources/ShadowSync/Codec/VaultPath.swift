import Foundation

import ShadowCore

public enum VaultObject: Sendable, Equatable {
  case hint
  case manifest(ReplicaID)
  case segment(ReplicaID, first: Int64, last: Int64, tag: ContentTag)
  case basePart(ReplicaID, upTo: Int64, tag: ContentTag, part: Int, parts: Int)
  case sealedKey(recipient: String, key: KeyID)
  case blobPart(name: String, part: Int, parts: Int)
  case moveNotice
  case unknown
}

public enum VaultPath {
  public static let maximumSequence: Int64 = 999_999_999_999
  public static let maximumParts = 9999
  public static let hint = objectKey("vault.json")
  public static let replicasPrefix = "replicas/"
  /// Beside the replica prefixes, so the listing every download makes already shows it.
  public static let moveNotice = objectKey(replicasPrefix + "moved")
  static let sequenceWidth = 12
  static let partWidth = 4
  static let recipientLength = 16
  static let blobNameLength = 64

  public static func replicaPrefix(_ replica: ReplicaID) -> String {
    replicasPrefix + replica.description + "/"
  }

  public static func manifest(_ replica: ReplicaID) -> ObjectKey {
    objectKey(replicaPrefix(replica) + "manifest")
  }

  public static func segmentPrefix(_ replica: ReplicaID) -> String {
    replicaPrefix(replica) + "seg/"
  }

  public static func segment(_ replica: ReplicaID, first: Int64, last: Int64, tag: ContentTag) -> ObjectKey {
    precondition(first >= 1 && first <= last && last <= maximumSequence, "a segment spans 1...\(maximumSequence) with first <= last")
    return objectKey(segmentPrefix(replica) + sequence(first) + "-" + sequence(last) + "-" + tag.description)
  }

  public static func basePrefix(_ replica: ReplicaID) -> String {
    replicaPrefix(replica) + "base/"
  }

  public static func basePart(_ replica: ReplicaID, upTo: Int64, tag: ContentTag, part: Int, parts: Int) -> ObjectKey {
    precondition(upTo >= 0 && upTo <= maximumSequence, "a base covers 0...\(maximumSequence)")
    return objectKey(basePrefix(replica) + sequence(upTo) + "-" + tag.description + "/" + partName(part, of: parts))
  }

  public static func sealedKey(recipient: String, key: KeyID) -> ObjectKey {
    precondition(CodecText.isLowerHex(recipient, count: recipientLength), "a recipient is \(recipientLength) lower-case hex characters")
    return objectKey("keys/" + recipient + "/" + key.description)
  }

  public static func blobPart(name: String, part: Int, parts: Int) -> ObjectKey {
    precondition(CodecText.isLowerHex(name, count: blobNameLength), "a blob name is \(blobNameLength) lower-case hex characters")
    return objectKey("blobs/" + name + "/" + partName(part, of: parts))
  }

  public static func classify(_ key: ObjectKey) -> VaultObject {
    let components = key.rawValue.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard let head = components.first else { return .unknown }
    switch (head, components.count) {
    case ("vault.json", 1): return .hint
    case ("keys", 3): return classifySealedKey(recipient: components[1], key: components[2])
    case ("blobs", 3): return classifyBlobPart(name: components[1], part: components[2])
    case ("replicas", 2) where components[1] == "moved": return .moveNotice
    case ("replicas", 3...5): return classifyReplicaObject(Array(components.dropFirst()))
    default: return .unknown
    }
  }

  static func isPart(_ part: Int, of parts: Int) -> Bool {
    part >= 1 && part <= parts && parts <= maximumParts
  }

  private static func classifySealedKey(recipient: String, key: String) -> VaultObject {
    guard CodecText.isLowerHex(recipient, count: recipientLength), let keyID = KeyID(key) else { return .unknown }
    return .sealedKey(recipient: recipient, key: keyID)
  }

  private static func classifyBlobPart(name: String, part: String) -> VaultObject {
    guard CodecText.isLowerHex(name, count: blobNameLength), let (part, parts) = parsePartName(part) else { return .unknown }
    return .blobPart(name: name, part: part, parts: parts)
  }

  private static func classifyReplicaObject(_ components: [String]) -> VaultObject {
    guard components.count >= 2, let replica = ReplicaID(components[0]) else { return .unknown }
    switch (components[1], components.count) {
    case ("manifest", 2):
      return .manifest(replica)
    case ("seg", 3):
      guard let (first, last, tag) = parseSegmentName(components[2]) else { return .unknown }
      return .segment(replica, first: first, last: last, tag: tag)
    case ("base", 4):
      guard let (upTo, tag) = parseBaseDirectory(components[2]), let (part, parts) = parsePartName(components[3]) else { return .unknown }
      return .basePart(replica, upTo: upTo, tag: tag, part: part, parts: parts)
    default:
      return .unknown
    }
  }

  private static func parseSegmentName(_ name: String) -> (Int64, Int64, ContentTag)? {
    let bytes = Array(name.utf8)
    let lastStart = sequenceWidth + 1
    let tagStart = lastStart + sequenceWidth + 1
    guard bytes.count == tagStart + ContentTag.length, bytes[sequenceWidth] == CodecText.dash, bytes[tagStart - 1] == CodecText.dash else { return nil }
    guard let first = CodecText.decimal(bytes[0..<sequenceWidth]), let last = CodecText.decimal(bytes[lastStart..<(tagStart - 1)]) else { return nil }
    guard first >= 1, first <= last, let tag = ContentTag(String(decoding: bytes[tagStart...], as: UTF8.self)) else { return nil }
    return (first, last, tag)
  }

  private static func parseBaseDirectory(_ name: String) -> (Int64, ContentTag)? {
    let bytes = Array(name.utf8)
    let tagStart = sequenceWidth + 1
    guard bytes.count == tagStart + ContentTag.length, bytes[sequenceWidth] == CodecText.dash else { return nil }
    guard let upTo = CodecText.decimal(bytes[0..<sequenceWidth]), let tag = ContentTag(String(decoding: bytes[tagStart...], as: UTF8.self)) else { return nil }
    return (upTo, tag)
  }

  private static func parsePartName(_ name: String) -> (Int, Int)? {
    let bytes = Array(name.utf8)
    let separator = Array("-of-".utf8)
    let partsStart = partWidth + separator.count
    guard bytes.count == partsStart + partWidth, bytes[partWidth..<partsStart].elementsEqual(separator) else { return nil }
    guard let part = CodecText.decimal(bytes[0..<partWidth]), let parts = CodecText.decimal(bytes[partsStart...]) else { return nil }
    guard isPart(Int(part), of: Int(parts)) else { return nil }
    return (Int(part), Int(parts))
  }

  private static func sequence(_ value: Int64) -> String {
    CodecText.padded(value, width: sequenceWidth)
  }

  private static func partName(_ part: Int, of parts: Int) -> String {
    precondition(isPart(part, of: parts), "a part number is in 1...parts and parts is at most \(maximumParts)")
    return CodecText.padded(part, width: partWidth) + "-of-" + CodecText.padded(parts, width: partWidth)
  }

  private static func objectKey(_ text: String) -> ObjectKey {
    guard let key = ObjectKey(text) else { preconditionFailure("a vault path is a valid object key: \(text)") }
    return key
  }
}
