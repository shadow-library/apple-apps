import Foundation
import ShadowText
import Testing

@testable import NovelForgeCore

enum ChecksFixtures {
  static func load(_ name: String) throws -> [OrderedJSON] {
    let text = String(decoding: try ReferenceFixture.data("checks/\(name)"), as: UTF8.self)
    return try #require(try OrderedJSON(parsing: text).arrayValue)
  }

  static func target(_ json: OrderedJSON) -> ResolvedWordTarget {
    json == .null ? .resolve() : ResolvedWordTarget(json: json)
  }
}

extension CheckFinding {
  var json: OrderedJSON { .record([("severity", .string(severity.rawValue)), ("text", .string(text))]) }
}

extension SimileFrameOveruse {
  var json: OrderedJSON { .record([("label", .string(label)), ("count", .number(count)), ("per1000Words", .number(per1000Words))]) }
}

extension ReadabilityEvidence {
  var json: OrderedJSON {
    .record([
      ("metrics", metrics.json), ("overLimits", .strings(overLimits)),
      ("flagged", .array(flagged.map { .record([("sentence", .string($0.sentence)), ("reason", .string($0.reason))]) })),
    ])
  }
}
