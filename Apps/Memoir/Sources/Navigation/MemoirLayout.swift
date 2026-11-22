import SwiftUI

enum MemoirLayout: Equatable, Sendable {
  case sidebar
  case tabs

  init(sizeClass: UserInterfaceSizeClass?) {
    self = sizeClass == .compact ? .tabs : .sidebar
  }
}
