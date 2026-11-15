import SwiftUI

nonisolated public enum ShadowAvatarTint: Hashable, Sendable {
  case accent
  case warm
  case neutral
  case solid
  case chart(Int)

  public static let chartCount = 8

  public static func automatic(for seed: String) -> Self {
    let normalized = seed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let hash = normalized.utf8.reduce(14_695_981_039_346_656_037 as UInt64) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    return .chart(Int(avalanche(hash) % UInt64(chartCount)) + 1)
  }

  // FNV-1a leaves any small bit range dependent on only a few input bits, so short names collide; MurmurHash3's fmix64 spreads every bit.
  static func avalanche(_ hash: UInt64) -> UInt64 {
    var mixed = hash ^ (hash >> 33)
    mixed &*= 0xff51_afd7_ed55_8ccd
    mixed ^= mixed >> 33
    mixed &*= 0xc4ce_b9fe_1a85_ec53
    return mixed ^ (mixed >> 33)
  }

  static let chartBackgrounds: [(light: ShadowRGBA, dark: ShadowRGBA)] = [
    (ShadowRGBA(hex: 0x1E569A), ShadowRGBA(hex: 0x2961A5)),
    (ShadowRGBA(hex: 0xA34520), ShadowRGBA(hex: 0x9C401B)),
    (ShadowRGBA(hex: 0x127251), ShadowRGBA(hex: 0x127251)),
    (ShadowRGBA(hex: 0x855800), ShadowRGBA(hex: 0x916000)),
    (ShadowRGBA(hex: 0x993A5D), ShadowRGBA(hex: 0x993A5D)),
    (ShadowRGBA(hex: 0x005E00), ShadowRGBA(hex: 0x005E00)),
    (ShadowRGBA(hex: 0x473A9A), ShadowRGBA(hex: 0x6860A8)),
    (ShadowRGBA(hex: 0xA33534), ShadowRGBA(hex: 0xA64A4A)),
  ]

  var chartBackground: (light: ShadowRGBA, dark: ShadowRGBA)? {
    guard case .chart(let index) = self else { return nil }
    return Self.chartBackgrounds[min(max(index, 1), Self.chartCount) - 1]
  }

  var background: Color {
    switch self {
    case .accent: ShadowColor.accentSoft
    case .warm: ShadowColor.warningBgSubtle
    case .neutral: ShadowColor.neutralBgSubtle
    case .solid: ShadowColor.neutralSolid
    case .chart: chartBackground.map { Color(light: $0.light, dark: $0.dark) } ?? ShadowColor.accentSoft
    }
  }

  var foreground: Color {
    switch self {
    case .accent: ShadowColor.accentText
    case .warm: ShadowColor.warningTextOnSubtle
    case .neutral: ShadowColor.neutralTextOnSubtle
    case .solid: ShadowColor.neutralOnSolid
    case .chart: ShadowColor.onAccent
    }
  }

  var filledBackground: Color {
    switch self {
    case .accent: ShadowColor.accent
    case .warm: ShadowColor.warningSolid
    case .neutral, .solid: ShadowColor.neutralSolid
    case .chart: background
    }
  }

  var filledForeground: Color {
    switch self {
    case .accent, .chart: ShadowColor.onAccent
    case .warm: ShadowColor.warningOnSolid
    case .neutral, .solid: ShadowColor.neutralOnSolid
    }
  }
}
