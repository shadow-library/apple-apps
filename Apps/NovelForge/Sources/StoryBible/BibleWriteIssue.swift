import Foundation

nonisolated enum BibleWriteIssue: Error, Equatable {
  case pageChanged(head: String?)
}
