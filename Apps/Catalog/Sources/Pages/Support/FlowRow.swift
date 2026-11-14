import ShadowDesignSystem
import SwiftUI

struct FlowRow: Layout {
  var spacing: CGFloat = Spacing.space3
  var lineSpacing: CGFloat = Spacing.space3

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
    let lines = lines(for: subviews, width: proposal.width ?? .infinity)
    let width = lines.map(\.width).max() ?? 0
    let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
    var y = bounds.minY
    for line in lines(for: subviews, width: bounds.width) {
      var x = bounds.minX
      for index in line.indices {
        let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += line.height + lineSpacing
    }
  }

  private struct Line {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func lines(for subviews: Subviews, width: CGFloat) -> [Line] {
    var lines: [Line] = []
    var current = Line()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
      let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if proposedWidth > width, !current.indices.isEmpty {
        lines.append(current)
        current = Line()
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { lines.append(current) }
    return lines
  }
}
