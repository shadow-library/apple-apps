import SwiftUI

/// How many columns of a ``ShadowAdaptiveColumns`` layout a view takes.
nonisolated public enum ShadowColumnSpan: Hashable, Sendable {
  case single
  case full
}

/// Flows sections into as many columns as fit the width, so a wide window fills with content instead of a single column and an empty side.
///
/// A column is added only when every column can be at least ``ShadowMetrics/columnMinWidth`` wide, up to `maxColumns`; a single column takes
/// whatever width it is given. No column grows past ``ShadowMetrics/readableWidth``. Each view goes
/// into the column that currently ends highest (the leading one on a tie). A view marked `.shadowColumnSpan(.full)`, or one too wide for a
/// column, starts below every column and spans them all; placement resumes below it. Use a full span for tables, native lists and anything
/// else that needs more than a column.
///
/// At accessibility text sizes the layout is a single column. The views keep the order you declare for VoiceOver and keyboard focus, which
/// is also the order they fill the columns in, so declare them in reading order.
///
/// The layout measures every view, so use it for bounded content such as the sections of a page or a handful of cards. For long or
/// unbounded collections use `LazyVGrid`, which only builds the visible rows.
///
/// Placement depends only on the current sizes, so a view that grows, such as an expanded disclosure group, can move the views after it to
/// another column. Give content that changes height a full span, or place it last, when that matters.
public struct ShadowAdaptiveColumns<Content: View>: View {
  private let maxColumns: Int
  private let minColumnWidth: CGFloat
  private let spacing: CGFloat
  private let rowSpacing: CGFloat
  private let content: Content

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  public init(
    maxColumns: Int = 2, minColumnWidth: CGFloat = ShadowMetrics.columnMinWidth, spacing: CGFloat = Spacing.space5, rowSpacing: CGFloat? = nil,
    @ViewBuilder content: () -> Content
  ) {
    precondition(maxColumns > 0, "ShadowAdaptiveColumns needs at least one column")
    self.maxColumns = maxColumns
    self.minColumnWidth = minColumnWidth
    self.spacing = spacing
    self.rowSpacing = rowSpacing ?? spacing
    self.content = content()
  }

  public var body: some View {
    ShadowColumnsLayout(
      maxColumns: dynamicTypeSize.isAccessibilitySize ? 1 : maxColumns, minColumnWidth: minColumnWidth, maxColumnWidth: ShadowMetrics.readableWidth,
      spacing: spacing, rowSpacing: rowSpacing
    ) {
      content
    }
  }
}

extension View {
  /// Sets how many columns of the enclosing ``ShadowAdaptiveColumns`` this view spans.
  public func shadowColumnSpan(_ span: ShadowColumnSpan) -> some View {
    layoutValue(key: ShadowColumnSpanKey.self, value: span)
  }
}

nonisolated private struct ShadowColumnSpanKey: LayoutValueKey {
  static let defaultValue = ShadowColumnSpan.single
}

nonisolated struct ShadowColumnItem {
  let span: ShadowColumnSpan
  let size: (CGFloat) -> CGSize
}

nonisolated struct ShadowColumnArrangement {
  var frames: [CGRect]
  var columns: [Int?]
  var size: CGSize
}

nonisolated struct ShadowColumnGrid: Equatable {
  private static let tolerance: CGFloat = 0.5

  let columnCount: Int
  let columnWidth: CGFloat
  let spacing: CGFloat

  init(width: CGFloat?, maxColumns: Int, minColumnWidth: CGFloat, maxColumnWidth: CGFloat, spacing: CGFloat) {
    self.spacing = spacing
    guard let width, width.isFinite else {
      columnCount = maxColumns
      columnWidth = maxColumnWidth
      return
    }
    let available = max(width, 0)
    let fitting = Int(((available + spacing + Self.tolerance) / (minColumnWidth + spacing)).rounded(.down))
    columnCount = min(max(fitting, 1), maxColumns)
    columnWidth = min(max((available - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount), 0), maxColumnWidth)
  }

  var width: CGFloat { columnWidth * CGFloat(columnCount) + spacing * CGFloat(columnCount - 1) }

  func arrange(_ items: [ShadowColumnItem], rowSpacing: CGFloat) -> ShadowColumnArrangement {
    var bottoms = Array(repeating: CGFloat.zero, count: columnCount)
    var arrangement = ShadowColumnArrangement(frames: [], columns: [], size: .zero)
    for item in items {
      let single = item.span == .single ? item.size(columnWidth) : nil
      if let single, single.width <= columnWidth + Self.tolerance {
        let column = shortest(bottoms)
        let frame = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: bottoms[column], width: columnWidth, height: single.height)
        if frame.height > 0 { bottoms[column] = frame.maxY + rowSpacing }
        arrangement.frames.append(frame)
        arrangement.columns.append(column)
      } else {
        let top = bottoms.max() ?? 0
        let frame = CGRect(x: 0, y: top, width: width, height: item.size(width).height)
        if frame.height > 0 { bottoms = bottoms.map { _ in frame.maxY + rowSpacing } }
        arrangement.frames.append(frame)
        arrangement.columns.append(nil)
      }
    }
    arrangement.size = CGSize(width: width, height: max((bottoms.max() ?? 0) - rowSpacing, 0))
    return arrangement
  }

  private func shortest(_ bottoms: [CGFloat]) -> Int {
    bottoms.indices.min { bottoms[$0] < bottoms[$1] - Self.tolerance } ?? 0
  }
}

nonisolated struct ShadowColumnsLayout: Layout {
  let maxColumns: Int
  let minColumnWidth: CGFloat
  let maxColumnWidth: CGFloat
  let spacing: CGFloat
  let rowSpacing: CGFloat

  struct Cache {
    var arrangement: (grid: ShadowColumnGrid, value: ShadowColumnArrangement)?
  }

  func makeCache(subviews: Subviews) -> Cache {
    Cache()
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    arrangement(width: proposal.width, subviews: subviews, cache: &cache).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
    let arrangement = arrangement(width: bounds.width, subviews: subviews, cache: &cache)
    for (subview, frame) in zip(subviews, arrangement.frames) {
      subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(width: frame.width, height: nil))
    }
  }

  private func arrangement(width: CGFloat?, subviews: Subviews, cache: inout Cache) -> ShadowColumnArrangement {
    let grid = ShadowColumnGrid(width: width, maxColumns: maxColumns, minColumnWidth: minColumnWidth, maxColumnWidth: maxColumnWidth, spacing: spacing)
    if let cached = cache.arrangement, cached.grid == grid { return cached.value }
    let items = subviews.map { subview in
      ShadowColumnItem(span: subview[ShadowColumnSpanKey.self]) { subview.sizeThatFits(ProposedViewSize(width: $0, height: nil)) }
    }
    let arrangement = grid.arrange(items, rowSpacing: rowSpacing)
    cache.arrangement = (grid, arrangement)
    return arrangement
  }
}
