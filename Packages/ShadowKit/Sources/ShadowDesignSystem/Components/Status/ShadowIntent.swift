import SwiftUI

nonisolated public enum ShadowIntent: Hashable, Sendable, CaseIterable {
  case neutral
  case info
  case success
  case warning
  case danger

  public var systemImage: String {
    switch self {
    case .neutral: "note.text"
    case .info: "info.circle"
    case .success: "checkmark.circle"
    case .warning: "exclamationmark.triangle"
    case .danger: "xmark.circle"
    }
  }

  public var compactSystemImage: String {
    switch self {
    case .neutral: "circle.dashed"
    case .info: "info.circle"
    case .success: "checkmark"
    case .warning: "exclamationmark.triangle"
    case .danger: "xmark"
    }
  }

  public var background: Color { backgroundToken.color }
  public var border: Color { borderToken.color }
  public var foreground: Color { foregroundToken.color }

  var backgroundToken: ShadowColorToken {
    switch self {
    case .neutral: .neutralBgSubtle
    case .info: .infoBgSubtle
    case .success: .successBgSubtle
    case .warning: .warningBgSubtle
    case .danger: .dangerBgSubtle
    }
  }

  var borderToken: ShadowColorToken {
    switch self {
    case .neutral: .neutralBorder
    case .info: .infoBorder
    case .success: .successBorder
    case .warning: .warningBorder
    case .danger: .dangerBorder
    }
  }

  var foregroundToken: ShadowColorToken {
    switch self {
    case .neutral: .neutralTextOnSubtle
    case .info: .infoTextOnSubtle
    case .success: .successTextOnSubtle
    case .warning: .warningTextOnSubtle
    case .danger: .dangerTextOnSubtle
    }
  }

  public var solid: Color {
    switch self {
    case .neutral: ShadowColor.neutralSolid
    case .info: ShadowColor.infoSolid
    case .success: ShadowColor.successSolid
    case .warning: ShadowColor.warningSolid
    case .danger: ShadowColor.dangerSolid
    }
  }
}
