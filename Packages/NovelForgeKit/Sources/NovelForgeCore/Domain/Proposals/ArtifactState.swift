import Foundation
import ShadowText

// apps/novel-forge-server/src/modules/refinement/artifact-state.ts:8
struct ArtifactState: Sendable, Equatable {
  let exists: Bool
  let revision: Int?
  let contentHash: String?

  // apps/novel-forge-server/src/modules/refinement/artifact-state.ts:31
  static let missing = ArtifactState(exists: false, revision: nil, contentHash: nil)
  static let unreadable = ArtifactState(exists: true, revision: nil, contentHash: nil)

  var isUnreadable: Bool { exists && contentHash == nil }

  func matches(_ current: ArtifactState) -> Bool { !isUnreadable && !current.isUnreadable && self == current }

  static func == (left: ArtifactState, right: ArtifactState) -> Bool {
    left.exists == right.exists && left.revision == right.revision && sameText(left.contentHash, right.contentHash)
  }

  var json: OrderedJSON {
    jsonObject([
      ("exists", .bool(exists)), ("revision", revision.map { .int(Int64($0)) } ?? .null), ("contentHash", contentHash.map(OrderedJSON.string) ?? .null),
    ])
  }

  init(exists: Bool, revision: Int?, contentHash: String?) {
    self.exists = exists
    self.revision = revision
    self.contentHash = contentHash
  }

  init?(json: OrderedJSON) {
    guard case .object(let record) = json, case .bool(let exists)? = record["exists"], let revision = Self.nullable(record["revision"], Self.integer),
      let contentHash = Self.nullable(record["contentHash"], \.stringValue)
    else { return nil }
    self.init(exists: exists, revision: revision, contentHash: contentHash)
  }

  private static func integer(_ value: OrderedJSON) -> Int? {
    guard let number = value.numberValue, number == number.rounded(), abs(number) <= Double(Int.max / 2) else { return nil }
    return Int(number)
  }

  private static func nullable<Value>(_ value: OrderedJSON?, _ convert: (OrderedJSON) -> Value?) -> Value?? {
    guard let value else { return nil }
    if value.isNull { return .some(nil) }
    return convert(value).map { .some($0) }
  }
}

func sameText(_ left: String?, _ right: String?) -> Bool {
  switch (left, right) {
  case (nil, nil): true
  case (let left?, let right?): left.jsEquals(right)
  default: false
  }
}

// artifact-state.ts:28
enum ArtifactRef: Sendable, Equatable {
  case premise
  case doc(section: String, slug: String)
  case volume(String)
  case chapter(Int)
  case draft(Int)
  case entity(String)
  case fact(String)
  case milestone(String)
  case promise(PromiseRef)

  init?(_ ref: String) {
    if ref.jsEquals("premise") {
      self = .premise
    } else if ref.jsStartsWith("doc:") {
      let parts = ref.jsSlice(4).jsSplit("/")
      self = .doc(section: parts.first ?? "", slug: parts.dropFirst().joined(separator: "/"))
    } else if ref.jsStartsWith("volume:") {
      self = .volume(ref.jsSlice(7))
    } else if ref.jsStartsWith("chapter:") {
      guard let chapter = Self.chapterNumber(ref.jsSlice(8)) else { return nil }
      self = .chapter(chapter)
    } else if ref.jsStartsWith("draft:") {
      guard let chapter = Self.chapterNumber(ref.jsSlice(6)) else { return nil }
      self = .draft(chapter)
    } else if ref.jsStartsWith("entity:") {
      self = .entity(ref.jsSlice(7))
    } else if ref.jsStartsWith("fact:") {
      self = .fact(ref.jsSlice(5))
    } else if ref.jsStartsWith("milestone:") {
      self = .milestone(ref.jsSlice(10))
    } else if ref.jsStartsWith("promise:") {
      let parts = ref.jsSlice(8).jsSplit(":")
      let key = parts.dropFirst().joined(separator: ":")
      switch parts.first {
      case "thread": self = .promise(.thread(key))
      case "mystery": self = .promise(.mystery(key))
      default: return nil
      }
    } else {
      return nil
    }
  }

  // The reference reports a chapter row under its canonical `chapter:<n>`, so a spelling that is not the canonical decimal finds nothing
  private static func chapterNumber(_ text: String) -> Int? {
    guard text.utf8.count <= 9, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let chapter = Int(text), chapter >= 1, String(chapter) == text else { return nil }
    return chapter
  }
}
