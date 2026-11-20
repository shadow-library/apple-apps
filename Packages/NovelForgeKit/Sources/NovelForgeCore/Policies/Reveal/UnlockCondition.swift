import ShadowCore
import ShadowText

enum UnlockTerm: Sendable {
  case milestone(String)
  case volume(String)
  case chapter(Int)
  case ending
}

extension UnlockTerm: Equatable {
  static func == (left: UnlockTerm, right: UnlockTerm) -> Bool {
    switch (left, right) {
    case (.milestone(let a), .milestone(let b)): a.jsEquals(b)
    case (.volume(let a), .volume(let b)): a.jsEquals(b)
    case (.chapter(let a), .chapter(let b)): a == b
    case (.ending, .ending): true
    default: false
    }
  }
}

extension UnlockTerm: Codable {
  private enum CodingKeys: String, CodingKey {
    case milestone
    case volume
    case chapter
    case ending
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.allKeys.count == 1, let key = container.allKeys.first else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "An unlock term has exactly one of milestone, volume, chapter, ending"))
    }
    switch key {
    case .milestone: self = .milestone(try container.decode(String.self, forKey: .milestone))
    case .volume: self = .volume(try container.decode(String.self, forKey: .volume))
    case .chapter: self = .chapter(try container.decode(Int.self, forKey: .chapter))
    case .ending:
      guard try container.decode(Bool.self, forKey: .ending) else {
        throw DecodingError.dataCorruptedError(forKey: .ending, in: container, debugDescription: "ending must be true")
      }
      self = .ending
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .milestone(let key): try container.encode(key, forKey: .milestone)
    case .volume(let key): try container.encode(key, forKey: .volume)
    case .chapter(let number): try container.encode(number, forKey: .chapter)
    case .ending: try container.encode(true, forKey: .ending)
    }
  }
}

struct UnlockCondition: Equatable, Sendable, Codable {
  var all: [UnlockTerm]
}

enum UnlockConditionError: ShadowError, Equatable {
  case invalid([String])

  var code: String { "unlock-condition.invalid" }

  var errorDescription: String? {
    switch self {
    case .invalid(let messages): "The unlock condition is invalid: \(messages.joined(separator: "; "))."
    }
  }
}

extension UnlockCondition {
  init?(validating value: OrderedJSON) {
    guard validateUnlockCondition(value).isEmpty, let terms = value.objectValue?["all"]?.arrayValue else { return nil }
    let parsed = terms.compactMap(UnlockTerm.init(validated:))
    guard parsed.count == terms.count else { return nil }
    self.init(all: parsed)
  }

  init(validating value: JSONValue) throws(UnlockConditionError) {
    let ordered = OrderedJSON(value)
    guard let condition = UnlockCondition(validating: ordered) else { throw .invalid(validateUnlockCondition(ordered)) }
    self = condition
  }

  var jsonValue: JSONValue {
    .object(["all": .array(all.map(\.jsonValue))])
  }
}

extension UnlockTerm {
  fileprivate init?(validated term: OrderedJSON) {
    guard let entry = term.objectValue?.entries.first else { return nil }
    switch (entry.key, entry.value) {
    case ("milestone", .string(let key)): self = .milestone(key)
    case ("volume", .string(let key)): self = .volume(key)
    case ("chapter", .int(let number)): self = .chapter(jsInteger(number))
    case ("chapter", .double(let number)): self = .chapter(jsInteger(number))
    case ("ending", .bool(true)): self = .ending
    default: return nil
    }
  }

  fileprivate var jsonValue: JSONValue {
    switch self {
    case .milestone(let key): .object(["milestone": .string(key)])
    case .volume(let key): .object(["volume": .string(key)])
    case .chapter(let number): .object(["chapter": .int(Int64(number))])
    case .ending: .object(["ending": .bool(true)])
    }
  }
}

private func jsInteger(_ number: Int64) -> Int {
  jsInteger(Double(number))
}

private func jsInteger(_ number: Double) -> Int {
  Int(exactly: number) ?? (number < 0 ? Int.min : Int.max)
}
