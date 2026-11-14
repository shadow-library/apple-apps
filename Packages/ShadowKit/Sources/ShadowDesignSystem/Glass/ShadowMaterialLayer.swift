import SwiftUI

nonisolated public enum ShadowMaterialLayer: Hashable, Sendable, CaseIterable {
  case navigation
  case glass
  case content

  public var allowsGlass: Bool { self == .navigation }
}

extension EnvironmentValues {
  @Entry public internal(set) var shadowMaterialLayer: ShadowMaterialLayer = .navigation
  @Entry var shadowGlassForeground: Color = ShadowColor.textPrimary
}
