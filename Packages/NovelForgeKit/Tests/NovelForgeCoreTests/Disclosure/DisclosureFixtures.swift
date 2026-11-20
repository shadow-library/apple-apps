import CryptoKit
import Foundation
import ShadowText

@testable import NovelForgeCore

enum DisclosureFixture {
  static func load(_ name: String) throws -> OrderedJSON {
    let text = String(decoding: try ReferenceFixture.data("disclosure/\(name)"), as: UTF8.self)
    return try OrderedJSON(parsing: text)
  }

  static func cases(_ name: String, _ key: String) throws -> [OrderedJSON] {
    try load(name).objectValue?[key]?.arrayValue ?? []
  }
}

extension OrderedJSON {
  func at(_ index: Int) -> OrderedJSON {
    items.indices.contains(index) ? items[index] : .null
  }

  var intValue: Int? { numberValue.map { Int($0) } }

  var bool: Bool { self == .bool(true) }

  var strings: [String]? { arrayValue?.map { $0.stringValue ?? "" } }

  /// A string, or the code units of one that is not well formed, read as `JSText` would read them (a lone half dropped).
  var encodedString: String {
    if let text = stringValue { return text }
    return JSText.string(fromCodeUnits: items.compactMap { $0.intValue.map { UInt16(truncatingIfNeeded: $0) } })
  }

  var throwsMarker: Bool { items.count == 1 && items.first == .string("throws") }

  /// The generator's `{ o: [[key, value], ...] }` keeps key order; any other value is read as is.
  var tagged: OrderedJSON {
    switch self {
    case .array(let values): return .array(values.map(\.tagged))
    case .object(let object):
      guard object.keys.count == 1, let pairs = object["o"]?.arrayValue else { return self }
      return .object(OrderedJSONObject(pairs.map { (key: $0.at(0).stringValue ?? "", value: $0.at(1).tagged) }))
    default: return self
    }
  }
}

func sameText(_ left: String?, _ right: String?) -> Bool {
  switch (left, right) {
  case (nil, nil): true
  case (let a?, let b?): a.jsEquals(b)
  default: false
  }
}

func sameTexts(_ left: [String], _ right: [String]) -> Bool {
  left.count == right.count && zip(left, right).allSatisfy { $0.jsEquals($1) }
}

func codePointSorted(_ keys: [String]) -> [String] {
  keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
}

func fixtureFact(_ row: OrderedJSON) -> DisclosureFact {
  let unlock: FactUnlock? =
    switch row.at(10) {
    case .null: nil
    case let value: UnlockCondition(validating: value).map(FactUnlock.condition) ?? .unreadable
    }
  return DisclosureFact(
    factKey: row.at(0).stringValue ?? "", text: row.at(1).stringValue ?? "", constraintNote: row.at(2).stringValue, writerNote: row.at(3).stringValue, terms: row.at(4).strings,
    allowedClues: row.at(5).strings, subjects: row.at(6).strings, source: row.at(7).stringValue.flatMap(FactSource.init(rawValue:)), disclosedInChapter: row.at(8).intValue,
    revealChapter: row.at(9).intValue, unlock: unlock)
}

func fixturePlan(_ row: OrderedJSON) -> DisclosurePlan {
  let claims = PlanClaims(chapter: row.at(0).intValue ?? 0, volumeKey: row.at(1).stringValue, isEnding: row.at(2).bool, claimedMilestones: row.at(3).strings)
  return DisclosurePlan(unnormalized: PlanRow(claims: claims, knowledgeContract: row.at(4).tagged), endingContract: row.at(5).tagged)
}

func fixtureWorld(_ row: OrderedJSON, readerKnowsLabel: Bool = false) -> DisclosureWorld {
  DisclosureWorld(
    ending: row.at(8).stringValue, endingQuestion: row.at(9).stringValue, facts: row.at(0).items.map(fixtureFact),
    entities: row.at(2).items.map { DisclosureEntity(entityKey: $0.at(0).stringValue ?? "", name: $0.at(1).stringValue ?? "") },
    knowledge: row.at(4).items.map {
      KnowledgeRow(
        factKey: $0.at(0).stringValue ?? "", entityKey: $0.at(1).stringValue ?? "", learnedInChapter: $0.at(2).intValue ?? 0,
        source: $0.at(3).stringValue.flatMap(FactSource.init(rawValue:)),
        status: $0.at(4).stringValue.flatMap(KnowledgeStatus.init(rawValue:)) ?? .committed, draftRevision: $0.at(5).intValue)
    },
    plans: row.at(5).items.map(fixturePlan),
    milestones: row.at(6).items.map {
      MilestoneRow(milestoneKey: $0.at(0).stringValue ?? "", state: $0.at(1).stringValue.flatMap(MilestoneState.init(rawValue:)) ?? .open, reachedChapter: $0.at(2).intValue)
    },
    volumes: row.at(7).items.map {
      DisclosureVolume(
        volumeKey: $0.at(0).stringValue ?? "", ordinal: $0.at(1).intValue ?? 0, title: $0.at(2).stringValue, objective: $0.at(3).stringValue, body: $0.at(4).stringValue)
    },
    pages: row.at(10).items.map {
      DisclosurePage(address: BibleDocAddress(section: $0.at(0).stringValue ?? "", slug: $0.at(1).stringValue ?? ""), body: $0.at(2).stringValue ?? "")
    },
    drafts: row.at(11).items.compactMap(fixtureDraft), readerKnowsLabel: readerKnowsLabel)
}

func fixtureDraft(_ row: OrderedJSON) -> DraftRow? {
  guard let status = row.at(2).stringValue.flatMap(DraftStatus.init(rawValue:)), let review = row.at(3).stringValue.flatMap(DraftReviewStatus.init(rawValue:)) else { return nil }
  return DraftRow(chapter: row.at(0).intValue ?? 0, revision: row.at(1).intValue ?? 0, status: status, reviewStatus: review)
}

func withholdingDigest(_ policy: WriterDisclosurePolicy) -> String {
  let lines = policy.withholdings.map { "\($0.pattern.source)\u{1}\($0.pattern.flags)\u{1}\($0.weight)\u{1}\($0.copyFieldsOnly ? 1 : 0)" }
  return SHA256.hash(data: Array(lines.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
}

func contextRow(_ context: UnlockContext) -> OrderedJSON {
  .array([
    .int(Int64(context.chapter)), context.endingChapter.map { .int(Int64($0)) } ?? .null, context.volumeKey.map(OrderedJSON.string) ?? .null,
    .array(codePointSorted(context.reachedMilestones.map(\.value)).map(OrderedJSON.string)),
  ])
}
