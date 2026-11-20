import Foundation
import ShadowText

struct ChapterSummarizeOutput: Equatable, Sendable {
  var summary: String
  var state: OrderedJSONObject

  init?(json: OrderedJSON) {
    guard let record = json.objectValue, let summary = record["summary"]?.stringValue, let state = record["state"]?.objectValue else { return nil }
    self.summary = summary
    self.state = state
  }
}
