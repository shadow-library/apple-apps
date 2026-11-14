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

  public var background: Color {
    switch self {
    case .neutral: ShadowColor.neutralBgSubtle
    case .info: ShadowColor.infoBgSubtle
    case .success: ShadowColor.successBgSubtle
    case .warning: ShadowColor.warningBgSubtle
    case .danger: ShadowColor.dangerBgSubtle
    }
  }

  public var border: Color {
    switch self {
    case .neutral: ShadowColor.neutralBorder
    case .info: ShadowColor.infoBorder
    case .success: ShadowColor.successBorder
    case .warning: ShadowColor.warningBorder
    case .danger: ShadowColor.dangerBorder
    }
  }

  public var foreground: Color {
    switch self {
    case .neutral: ShadowColor.neutralTextOnSubtle
    case .info: ShadowColor.infoTextOnSubtle
    case .success: ShadowColor.successTextOnSubtle
    case .warning: ShadowColor.warningTextOnSubtle
    case .danger: ShadowColor.dangerTextOnSubtle
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
