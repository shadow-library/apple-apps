import SwiftUI

enum NovelLayout: Equatable, Sendable {
  case regular
  case compact

  init(sizeClass: UserInterfaceSizeClass?) {
    self = sizeClass == .compact ? .compact : .regular
  }
}
