import ShadowDesignSystem
import SwiftUI

enum DemoTableSizing: Hashable {
  case fitsContent(estimatedRows: Int)
  case rows(Int)
  case scrolling(visibleRows: Int)
}

private struct DemoTableFrame: ViewModifier {
  let sizing: DemoTableSizing

  @State private var contentHeight: CGFloat?
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .body) private var scale = 1

  private var isList: Bool { ShadowTableLayout(horizontalSizeClass: horizontalSizeClass, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) == .list }

  private func estimate(rows: Int) -> CGFloat {
    let count = CGFloat(rows)
    if isList { return count * 61 * scale + 56 }
    return (ShadowDensity.current == .touch ? 53 : 28) * scale * (count + 1) + 6
  }

  private var height: CGFloat {
    switch sizing {
    case .rows(let rows): estimate(rows: rows)
    case .fitsContent(let estimatedRows): contentHeight ?? estimate(rows: estimatedRows)
    case .scrolling(let visibleRows): min(contentHeight ?? .infinity, estimate(rows: visibleRows))
    }
  }

  private var isFixed: Bool {
    if case .rows = sizing { return true }
    return false
  }

  func body(content: Content) -> some View {
    content
      .scrollDisabled(contentHeight != nil && height == contentHeight)
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        guard geometry.contentSize.height > 0 else { return 0 }
        return (geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom).rounded(.up)
      } action: { _, newValue in
        if newValue > 0 && !isFixed { contentHeight = newValue }
      }
      .frame(height: height)
      .clipShape(.rect(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous).strokeBorder(ShadowColor.borderDefault, lineWidth: 1) }
  }
}

extension View {
  func demoTableFrame(_ sizing: DemoTableSizing) -> some View {
    modifier(DemoTableFrame(sizing: sizing))
  }
}
