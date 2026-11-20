import Foundation
import ShadowText

@testable import NovelForgeCore

struct FixtureJSON: Decodable {
  let value: OrderedJSON

  private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  private struct Pair: Decodable {
    let key: String
    let value: FixtureJSON

    init(from decoder: any Decoder) throws {
      var container = try decoder.unkeyedContainer()
      key = try container.decode(String.self)
      value = try container.decode(FixtureJSON.self)
    }
  }

  init(from decoder: any Decoder) throws {
    let single = try decoder.singleValueContainer()
    if single.decodeNil() {
      value = .null
    } else if let flag = try? single.decode(Bool.self) {
      value = .bool(flag)
    } else if let number = try? single.decode(Int64.self) {
      value = .int(number)
    } else if let number = try? single.decode(Double.self) {
      value = .double(number)
    } else if let text = try? single.decode(String.self) {
      value = .string(text)
    } else if let items = try? single.decode([FixtureJSON].self) {
      value = .array(items.map(\.value))
    } else {
      let keyed = try decoder.container(keyedBy: AnyKey.self)
      if let ordered = AnyKey(stringValue: "o"), keyed.contains(ordered) {
        value = .object(OrderedJSONObject(try keyed.decode([Pair].self, forKey: ordered).map { (key: $0.key, value: $0.value.value) }))
      } else if let learns = AnyKey(stringValue: "learns") {
        let factKeys = try keyed.decode([String].self, forKey: learns)
        let entries = factKeys.map { OrderedJSON.object(OrderedJSONObject([(key: "entityKey", value: .string("mira")), (key: "factKey", value: .string($0))])) }
        value = .object(OrderedJSONObject([(key: "pov", value: .array([.string("mira")])), (key: "learns", value: .array(entries))]))
      } else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown fixture value"))
      }
    }
  }
}

struct OrdinalPair: Decodable {
  let key: String
  let ordinal: Int

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    key = try container.decode(String.self)
    ordinal = try container.decode(Int.self)
  }
}

func ordinals(_ pairs: [OrdinalPair]) -> [JSString: Int] {
  var result: [JSString: Int] = [:]
  for pair in pairs { result[JSString(pair.key)] = pair.ordinal }
  return result
}

struct FixtureContext: Decodable {
  let context: UnlockContext

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    let chapter = try container.decode(Int.self)
    let endingChapter = try container.decodeOptional(Int.self)
    let volumeKey = try container.decodeOptional(String.self)
    let pairs = try container.decode([OrdinalPair].self)
    let reached = try container.decode([String].self)
    context = UnlockContext(
      chapter: chapter, endingChapter: endingChapter, volumeKey: volumeKey, volumeOrdinals: ordinals(pairs), reachedMilestones: Set(reached.map { JSString($0) }))
  }
}

struct FixtureFact: Decodable {
  let fact: RevealFact

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    let factKey = try container.decode(String.self)
    let revealChapter = try container.decodeOptional(Int.self)
    let unlock = try container.decodeOptional(UnlockCondition.self)
    let source = try container.decode(String.self)
    guard let parsed = FactSource(rawValue: source) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown source \(source)") }
    fact = RevealFact(factKey: factKey, revealChapter: revealChapter, unlock: unlock, source: parsed)
  }
}

func sameStrings(_ left: [String], _ right: [String]) -> Bool {
  left.count == right.count && zip(left, right).allSatisfy { $0.jsEquals($1) }
}

func sameOptional(_ left: String?, _ right: String?) -> Bool {
  switch (left, right) {
  case (nil, nil): true
  case (let a?, let b?): a.jsEquals(b)
  default: false
  }
}

func reachedList(_ context: UnlockContext) -> [String] {
  context.reachedMilestones.map(\.value).jsSorted()
}

func described(_ terms: [UnlockTerm]) -> [String] {
  terms.map(describeUnlockTerm)
}

extension UnkeyedDecodingContainer {
  mutating func decodeOptional<Value: Decodable>(_ type: Value.Type) throws -> Value? {
    if try decodeNil() { return nil }
    return try decode(Value.self)
  }
}
