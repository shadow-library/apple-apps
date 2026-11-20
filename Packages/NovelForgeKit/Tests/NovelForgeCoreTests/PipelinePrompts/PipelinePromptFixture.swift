import Foundation
import ShadowText

@testable import NovelForgeCore

enum PipelinePromptFixture {
  static let root: OrderedJSON = {
    do { return try OrderedJSON(parsing: String(decoding: try ReferenceFixture.data("prompts-pipelines/prompts-pipelines.json"), as: UTF8.self)) } catch {
      preconditionFailure("prompts-pipelines.json is unreadable: \(error)")
    }
  }()

  static func path(_ keys: String...) -> OrderedJSON {
    keys.reduce(root) { $0.pField($1) }
  }

  static func cases(_ keys: String...) -> [OrderedJSON] {
    keys.reduce(root) { $0.pField($1) }.pItems
  }
}

func samePipelineRequest(_ request: ChapterPromptRequest, _ entry: OrderedJSON, key: String = "messages") -> Bool {
  sameMessages(request.messages, entry.pField(key).pMessages)
}

func breakpoints(_ entry: OrderedJSON) -> [Int] {
  entry.pField("breakpoints").pItems.map { Int($0.numberValue ?? -1) }
}
