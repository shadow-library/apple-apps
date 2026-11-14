import SwiftUI

nonisolated public enum ShadowDensity: Sendable, CaseIterable {
  case touch
  case compact

  public static var current: Self {
    #if os(macOS)
      .compact
    #else
      .touch
    #endif
  }

  public func controlHeight(_ size: ShadowControlSize) -> CGFloat {
    switch (self, size) {
    case (.touch, .small): ShadowMetrics.controlTouchSm
    case (.touch, .medium): ShadowMetrics.controlTouchMd
    case (.touch, .large): ShadowMetrics.controlTouchLg
    case (.compact, .small): ShadowMetrics.controlMacSm
    case (.compact, .medium): ShadowMetrics.controlMacMd
    case (.compact, .large): ShadowMetrics.controlMacLg
    }
  }

  public var rowHeight: CGFloat {
    self == .touch ? ShadowMetrics.rowTouch : ShadowMetrics.rowMac
  }

  public var sidebarWidth: CGFloat {
    self == .touch ? ShadowMetrics.sidebarIpad : ShadowMetrics.sidebarMac
  }
}

nonisolated public enum ShadowControlSize: Sendable, CaseIterable {
  case small
  case medium
  case large

  public init(_ controlSize: ControlSize) {
    switch controlSize {
    case .mini, .small: self = .small
    case .large, .extraLarge: self = .large
    case .regular: self = .medium
    @unknown default: self = .medium
    }
  }
}

nonisolated extension ShadowMetrics {
  public static func control(_ size: ShadowControlSize) -> CGFloat {
    ShadowDensity.current.controlHeight(size)
  }

  public static var rowHeight: CGFloat { ShadowDensity.current.rowHeight }

  public static var sidebarWidth: CGFloat { ShadowDensity.current.sidebarWidth }
}
