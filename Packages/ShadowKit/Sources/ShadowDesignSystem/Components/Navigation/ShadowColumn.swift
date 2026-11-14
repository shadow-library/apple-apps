import SwiftUI

nonisolated public struct ShadowColumnWidth: Hashable, Sendable {
  public let minimum: CGFloat
  public let ideal: CGFloat
  public let maximum: CGFloat
}

nonisolated public enum ShadowColumn: Hashable, Sendable, CaseIterable {
  case sidebar
  case inspector

  public func width(for density: ShadowDensity = .current) -> ShadowColumnWidth {
    switch (self, density) {
    case (.sidebar, .touch): ShadowColumnWidth(minimum: 280, ideal: ShadowMetrics.sidebarIpad, maximum: ShadowMetrics.sidebarIpad)
    case (.sidebar, .compact): ShadowColumnWidth(minimum: 180, ideal: ShadowMetrics.sidebarMac, maximum: 360)
    case (.inspector, .touch): ShadowColumnWidth(minimum: ShadowMetrics.inspector, ideal: ShadowMetrics.inspector, maximum: ShadowMetrics.inspector)
    case (.inspector, .compact): ShadowColumnWidth(minimum: 260, ideal: ShadowMetrics.inspector, maximum: 420)
    }
  }
}

private struct ShadowColumnWidthModifier: ViewModifier {
  let column: ShadowColumn

  func body(content: Content) -> some View {
    let width = column.width()
    switch column {
    case .sidebar: content.navigationSplitViewColumnWidth(min: width.minimum, ideal: width.ideal, max: width.maximum)
    case .inspector:
      #if os(visionOS)
        content
      #else
        content.inspectorColumnWidth(min: width.minimum, ideal: width.ideal, max: width.maximum)
      #endif
    }
  }
}

extension View {
  public func shadowColumnWidth(_ column: ShadowColumn) -> some View {
    modifier(ShadowColumnWidthModifier(column: column))
  }
}
