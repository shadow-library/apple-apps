import Foundation
import ShadowText

@testable import NovelForgeCore

enum ChapterPromptFixture {
  static let root: OrderedJSON = {
    do { return try OrderedJSON(parsing: String(decoding: try ReferenceFixture.data("prompts-chapters/prompts-chapters.json"), as: UTF8.self)) } catch {
      preconditionFailure("prompts-chapters.json is unreadable: \(error)")
    }
  }()

  static func path(_ keys: String...) -> OrderedJSON {
    keys.reduce(root) { $0.pField($1) }
  }

  static func cases(_ keys: String...) -> [OrderedJSON] {
    keys.reduce(root) { $0.pField($1) }.pItems
  }
}

extension OrderedJSON {
  var pNumber: Double { numberValue ?? 0 }

  var pBreakpoints: [Int] { pItems.map { Int($0.pNumber) } }
}

func sameRequest(_ request: ChapterPromptRequest, _ entry: OrderedJSON) -> Bool {
  sameMessages(request.messages, entry.pField("messages").pMessages) && request.cacheBreakpoints == entry.pField("breakpoints").pBreakpoints
}
