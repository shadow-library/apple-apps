import SwiftUI

public struct ShadowFlowLayout: Layout {
  public var spacing: CGFloat
  public var lineSpacing: CGFloat

  public init(spacing: CGFloat = Spacing.space2, lineSpacing: CGFloat? = nil) {
    self.spacing = spacing
    self.lineSpacing = lineSpacing ?? spacing
  }

  public struct Cache {
    fileprivate var maxWidth: CGFloat?
    fileprivate var lines: [Line] = []
  }

  public func makeCache(subviews: Subviews) -> Cache {
    Cache()
  }

  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    let lines = lines(for: subviews, maxWidth: maxWidth, cache: &cache)
    let contentWidth = lines.map(\.width).max() ?? 0
    let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
    let fills = subviews.contains { $0[ShadowFlowFillKey.self] }
    return CGSize(width: fills && maxWidth.isFinite ? maxWidth : contentWidth, height: height)
  }

  public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
    var y = bounds.minY
    for line in lines(for: subviews, maxWidth: bounds.width, cache: &cache) {
      let fillCount = line.items.filter(\.fills).count
      let extra = fillCount > 0 ? max(bounds.width - line.width, 0) / CGFloat(fillCount) : 0
      var x = bounds.minX
      for item in line.items {
        let width = item.size.width + (item.fills ? extra : 0)
        let origin = CGPoint(x: x, y: y + (line.height - item.size.height) / 2)
        subviews[item.index].place(at: origin, proposal: ProposedViewSize(width: width, height: item.size.height))
        x += width + spacing
      }
      y += line.height + lineSpacing
    }
  }

  fileprivate struct Item {
    let index: Int
    let size: CGSize
    let fills: Bool
  }

  fileprivate struct Line {
    var items: [Item] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func lines(for subviews: Subviews, maxWidth: CGFloat, cache: inout Cache) -> [Line] {
    if cache.maxWidth == maxWidth { return cache.lines }
    let lines = lines(for: subviews, maxWidth: maxWidth)
    cache.maxWidth = maxWidth
    cache.lines = lines
    return lines
  }

  private func lines(for subviews: Subviews, maxWidth: CGFloat) -> [Line] {
    var lines: [Line] = []
    var current = Line()
    for index in subviews.indices {
      let item = measure(subviews[index], index: index, maxWidth: maxWidth)
      if !current.items.isEmpty, current.width + spacing + item.size.width > maxWidth + 0.5 {
        lines.append(current)
        current = Line()
      }
      current.width += (current.items.isEmpty ? 0 : spacing) + item.size.width
      current.height = max(current.height, item.size.height)
      current.items.append(item)
    }
    if !current.items.isEmpty { lines.append(current) }
    return lines
  }

  private func measure(_ subview: LayoutSubview, index: Int, maxWidth: CGFloat) -> Item {
    let fills = subview[ShadowFlowFillKey.self]
    let size = subview.sizeThatFits(fills ? .unspecified : ProposedViewSize(width: maxWidth, height: nil))
    return Item(index: index, size: CGSize(width: min(size.width, maxWidth), height: size.height), fills: fills)
  }
}

nonisolated private struct ShadowFlowFillKey: LayoutValueKey {
  static let defaultValue = false
}

extension View {
  public func shadowFlowFill() -> some View {
    layoutValue(key: ShadowFlowFillKey.self, value: true)
  }
}
