import Foundation

enum ReaderRoute: Hashable, Sendable {
  case chapter(Int)
  case versions(Int)
}
