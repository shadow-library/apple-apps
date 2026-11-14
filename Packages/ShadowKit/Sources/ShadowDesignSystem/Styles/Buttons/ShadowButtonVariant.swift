import SwiftUI

nonisolated public enum ShadowButtonVariant: Hashable, Sendable, CaseIterable {
  case filled
  case tinted
  case bordered
  case plain
  case glass
  case glassProminent

  func appearance(in layer: ShadowMaterialLayer) -> ShadowButtonAppearance {
    switch (self, layer) {
    case (.filled, _), (.glassProminent, .glass), (.glassProminent, .content): .filled
    case (.tinted, _): .tinted
    case (.bordered, _), (.glass, .content): .bordered
    case (.plain, .glass), (.glass, .glass): .barItem
    case (.plain, _): .plain
    case (.glass, .navigation): .glass
    case (.glassProminent, .navigation): .glassProminent
    }
  }
}

nonisolated enum ShadowButtonAppearance: Hashable, Sendable, CaseIterable {
  case filled
  case tinted
  case bordered
  case plain
  case barItem
  case glass
  case glassProminent

  var isGlass: Bool { self == .glass || self == .glassProminent }
}

@_spi(Preview) nonisolated public enum ShadowButtonInteraction: Hashable, Sendable, CaseIterable {
  case idle
  case hovered
  case pressed
}
