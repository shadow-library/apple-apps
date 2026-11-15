import ShadowDesignSystem
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

enum DemoTableSizing: Hashable {
  case fitsContent(estimatedRows: Int)
  case rows(Int)
  case scrolling(visibleRows: Int)
}

private struct DemoTableFrame: ViewModifier {
  let sizing: DemoTableSizing

  @State private var scrollContentHeight: CGFloat?
  @State private var rowsExtent: CGFloat?
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .body) private var scale = 1

  private var contentHeight: CGFloat? { rowsExtent ?? scrollContentHeight }

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
        if newValue > 0 && !isFixed { scrollContentHeight = newValue }
      }
      .frame(height: height)
      .background { rowsExtentReader }
      .clipShape(.rect(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous).strokeBorder(ShadowColor.borderDefault, lineWidth: 1) }
  }

  @ViewBuilder
  private var rowsExtentReader: some View {
    #if canImport(UIKit)
      if !isFixed {
        DemoTableRowsExtentReader(scrollContentHeight: scrollContentHeight) { rowsExtent = $0 }
      }
    #endif
  }
}

#if canImport(UIKit)
  // UIKit tables pad their content below the last row and draw its bottom separator; scroll geometry only reports the padded size.
  private struct DemoTableRowsExtentReader: UIViewRepresentable {
    let scrollContentHeight: CGFloat?
    let onMeasure: (CGFloat?) -> Void

    func makeUIView(context: Context) -> UIView {
      let view = UIView()
      view.isUserInteractionEnabled = false
      return view
    }

    func updateUIView(_ view: UIView, context: Context) {
      DispatchQueue.main.async { onMeasure(view.demoTableRowsExtent) }
    }
  }

  extension UIView {
    fileprivate var demoTableRowsExtent: CGFloat? {
      var ancestor = superview
      while let container = ancestor {
        let extents = container.demoTableLists.filter { bounds.insetBy(dx: -1, dy: -1).contains(convert($0.bounds, from: $0)) }.compactMap(demoRowsExtent)
        if let extent = extents.max() { return extent.rounded(.up) }
        ancestor = container.superview
      }
      return nil
    }

    private var demoTableLists: [UICollectionView] {
      subviews.flatMap { subview in (subview as? UICollectionView).map { [$0] } ?? subview.demoTableLists }
    }

    private func demoRowsExtent(of list: UICollectionView) -> CGFloat? {
      let lastRow = (0..<list.numberOfSections).reversed().lazy.compactMap { section in
        list.numberOfItems(inSection: section) > 0 ? IndexPath(item: list.numberOfItems(inSection: section) - 1, section: section) : nil
      }.first
      guard let lastRow, let rowFrame = list.layoutAttributesForItem(at: lastRow)?.frame else { return nil }
      return list.convert(CGPoint(x: 0, y: list.bounds.minY), to: self).y + list.adjustedContentInset.top + rowFrame.maxY
    }
  }
#endif

extension View {
  func demoTableFrame(_ sizing: DemoTableSizing) -> some View {
    modifier(DemoTableFrame(sizing: sizing))
  }
}
