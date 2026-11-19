import Foundation
import Testing

@testable import NovelForgeCore

enum MetricsFixtures {
  static func load(_ name: String) throws -> [OrderedJSON] {
    let text = String(decoding: try ReferenceFixture.data("metrics/\(name)"), as: UTF8.self)
    return try #require(try OrderedJSON(parsing: text).arrayValue)
  }

  static func section(_ sections: [OrderedJSON], _ index: Int) throws -> [[OrderedJSON]] {
    try #require(sections[index].arrayValue).map { try #require($0.arrayValue) }
  }
}

extension OrderedJSON {
  subscript(key: String) -> OrderedJSON? { objectValue?[key] }

  var text: String { stringValue ?? "" }
  var items: [OrderedJSON] { arrayValue ?? [] }
  var int: Int { Int(numberValue ?? 0) }
}

extension ResolvedWordTarget {
  init(json: OrderedJSON) {
    self.init(min: json["min"]?.numberValue ?? 0, max: json["max"]?.numberValue ?? 0, aim: json["aim"]?.numberValue ?? 0)
  }
}

extension ChapterMetricsInput {
  init(json: OrderedJSON) {
    self.init(chapter: json["chapter"]?.int ?? 0, body: json["body"]?.text ?? "", hookType: json["hookType"]?.stringValue)
  }
}
