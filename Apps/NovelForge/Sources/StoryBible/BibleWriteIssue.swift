import Foundation

nonisolated enum BibleWriteIssue: Error, Equatable {
  case entityKeyTaken(String)
  case pageChanged(head: String?)
}
