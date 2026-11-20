import Foundation
import ShadowText

@testable import NovelForgeCore

struct TurnRelayFixture: Decodable {
  let scenarios: [Scenario]
  let describe: [DescribeRow]
  let sentenceEnds: [SentenceRow]

  static func load() throws -> TurnRelayFixture {
    try ReferenceFixture.decode(TurnRelayFixture.self, from: "turn-relay/cases.json")
  }

  struct Scenario: Decodable {
    let ops: [Op]
    let steps: [Step]
  }

  enum Op: Decodable {
    case call(unrestricted: Bool)
    case push(String)
    case restart
    case settle(String)
    case supersede
    case lookup(round: Int, tool: String, args: String, status: String)
    case user(String)
    case flush
    case done(String)
    case error(code: String, message: String)

    private enum Keys: String, CodingKey {
      case op, unrestricted, raw, round, tool, args, status, message, reply, code
    }

    init(from decoder: any Decoder) throws {
      if let chunk = try? decoder.singleValueContainer().decode(String.self) {
        self = .push(chunk)
        return
      }
      let container = try decoder.container(keyedBy: Keys.self)
      switch try container.decode(String.self, forKey: .op) {
      case "call": self = .call(unrestricted: try container.decode(Bool.self, forKey: .unrestricted))
      case "restart": self = .restart
      case "settle": self = .settle(try container.decode(String.self, forKey: .raw))
      case "supersede": self = .supersede
      case "lookup":
        self = .lookup(
          round: try container.decode(Int.self, forKey: .round), tool: try container.decode(String.self, forKey: .tool),
          args: try container.decode(String.self, forKey: .args), status: try container.decode(String.self, forKey: .status))
      case "user": self = .user(try container.decode(String.self, forKey: .message))
      case "flush": self = .flush
      case "done": self = .done(try container.decode(String.self, forKey: .reply))
      case "error": self = .error(code: try container.decode(String.self, forKey: .code), message: try container.decode(String.self, forKey: .message))
      case let other: throw DecodingError.dataCorruptedError(forKey: .op, in: container, debugDescription: "unknown op \(other)")
      }
    }
  }

  /// One step of the reference, as `[name, ...values]` arrays: `["delta", text]`, `["change", index, json]` or `["change", index, op, label, group]`, `["reset"]`.
  struct Step: Decodable {
    let index: Int
    let relay: [[Value]]
    let turn: [[Value]]
    let frames: [Frame]

    init(from decoder: any Decoder) throws {
      var container = try decoder.unkeyedContainer()
      index = try container.decode(Int.self)
      relay = try container.decodeIfPresent([[Value]].self) ?? []
      turn = try container.decodeIfPresent([[Value]].self) ?? []
      frames = try container.decodeIfPresent([Frame].self) ?? []
    }
  }

  struct Frame: Decodable, Equatable {
    let sequence: Int
    let event: String
    let data: String

    init(sequence: Int, event: String, data: String) {
      self.sequence = sequence
      self.event = event
      self.data = data
    }

    init(from decoder: any Decoder) throws {
      var container = try decoder.unkeyedContainer()
      sequence = try container.decode(Int.self)
      event = try container.decode(String.self)
      data = try container.decode(String.self)
    }
  }

  enum Value: Decodable, Equatable {
    case text(String)
    case number(Int)

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let number = try? container.decode(Int.self) {
        self = .number(number)
      } else {
        self = .text(try container.decode(String.self))
      }
    }
  }

  struct DescribeRow: Decodable {
    let element: String
    let index: Int
    let op: String
    let label: String
    let group: String
  }

  struct SentenceRow: Decodable {
    let text: String
    let released: [String]
  }
}

/// The reference fixture's refusal: any text holding the marker, matched by code unit as `String.prototype.includes` does.
let fixtureVeto: @Sendable (String) -> Bool = { $0.jsIndexOf("VETO") >= 0 }

/// Events as the fixture writes them, so a mismatch prints both sides alike.
func fixtureValues(_ event: ReplyStreamEvent) -> [TurnRelayFixture.Value] {
  switch event {
  case .delta(let text): [.text("delta"), .text(text)]
  case .change(let change): [.text("change"), .number(change.index), .text((try? OrderedJSON(parsing: change.element.source))?.jsonText ?? change.element.source)]
  case .reset: [.text("reset")]
  }
}

func fixtureValues(_ event: TurnStreamEvent) -> [TurnRelayFixture.Value] {
  switch event {
  case .delta(let text): [.text("delta"), .text(text)]
  case .change(let change): [.text("change"), .number(change.index), .text(change.op), .text(change.label), .text(change.group.rawValue)]
  case .reset: [.text("reset")]
  default: [.text(event.name.rawValue)]
  }
}

func jsEqual(_ left: [[TurnRelayFixture.Value]], _ right: [[TurnRelayFixture.Value]]) -> Bool {
  left.count == right.count
    && zip(left, right).allSatisfy { pair in
      pair.0.count == pair.1.count
        && zip(pair.0, pair.1).allSatisfy { values in
          switch values {
          case (.text(let a), .text(let b)): a.jsEquals(b)
          case (.number(let a), .number(let b)): a == b
          default: false
          }
        }
    }
}
