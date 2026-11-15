import SwiftUI

public struct ShadowDeltaBadge: View {
  private let delta: ShadowDelta
  private let unit: ShadowDeltaUnit

  @Environment(\.locale) private var locale
  @ScaledMetric(relativeTo: .caption) private var arrowSize = Spacing.space3

  public init(_ delta: ShadowDelta, unit: ShadowDeltaUnit = .none) {
    self.delta = delta
    self.unit = unit
  }

  private var intent: ShadowIntent {
    switch delta.sentiment {
    case .positive: .success
    case .negative: .danger
    case .neutral: .neutral
    }
  }

  public var body: some View {
    HStack(spacing: Spacing.space05 + Spacing.space05) {
      Image(systemName: delta.systemImage)
        .font(.system(size: arrowSize, weight: .bold))
        .accessibilityHidden(true)
      Text(verbatim: delta.magnitudeText(unit: unit, locale: locale))
        .monospacedDigit()
    }
    .font(Font.shadow(.caption).weight(.semibold))
    .foregroundStyle(intent.foreground)
    .padding(.horizontal, Spacing.space2 - Spacing.space05)
    .padding(.vertical, Spacing.space05)
    .background(intent.background, in: .capsule)
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: delta.signedText(unit: unit, locale: locale)))
  }
}

public struct ShadowStatistic<Accessory: View>: View {
  private let label: Text
  private let value: Text
  private let delta: ShadowDeltaBadge?
  private let caption: Text?
  private let accessory: Accessory

  public init(_ labelKey: LocalizedStringKey, value: Text, delta: ShadowDeltaBadge? = nil, caption: Text? = nil, @ViewBuilder accessory: () -> Accessory) {
    label = Text(labelKey)
    self.value = value
    self.delta = delta
    self.caption = caption
    self.accessory = accessory()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space05) {
      label
        .shadowFont(.footnote)
        .fontWeight(.medium)
        .foregroundStyle(ShadowColor.textSecondary)
      value
        .shadowFont(.title)
        .monospacedDigit()
        .foregroundStyle(ShadowColor.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      if let delta { delta.padding(.top, Spacing.space05) }
      if let caption {
        caption
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
      }
      accessory
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .shadowCard()
    .accessibilityElement(children: .combine)
  }
}

extension ShadowStatistic where Accessory == EmptyView {
  public init(_ labelKey: LocalizedStringKey, value: Text, delta: ShadowDeltaBadge? = nil, caption: Text? = nil) {
    self.init(labelKey, value: value, delta: delta, caption: caption) { EmptyView() }
  }
}

public struct ShadowCapacityStatistic: View {
  private let label: Text
  private let valueText: Text
  private let caption: Text?
  private let value: Double
  private let range: ClosedRange<Double>

  public init(_ labelKey: LocalizedStringKey, value: Double, in range: ClosedRange<Double> = 0...1, valueText: Text, caption: Text? = nil) {
    label = Text(labelKey)
    self.value = value
    self.range = range
    self.valueText = valueText
    self.caption = caption
  }

  public var body: some View {
    HStack(spacing: Spacing.space4) {
      ShadowCapacityGauge(title: label, value: value, in: range, showsTitle: false)
      VStack(alignment: .leading, spacing: Spacing.space05) {
        label
          .shadowFont(.footnote)
          .fontWeight(.medium)
          .foregroundStyle(ShadowColor.textSecondary)
        valueText
          .shadowFont(.headline)
          .monospacedDigit()
          .foregroundStyle(ShadowColor.textPrimary)
        if let caption {
          caption
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .shadowCard()
    .accessibilityElement(children: .combine)
  }
}

public struct ShadowStatisticGrid<Content: View>: View {
  @ScaledMetric private var minimumWidth: CGFloat
  private let content: Content

  public init(minimumWidth: CGFloat = 140, @ViewBuilder content: () -> Content) {
    _minimumWidth = ScaledMetric(wrappedValue: minimumWidth, relativeTo: .body)
    self.content = content()
  }

  public var body: some View {
    ShadowStatisticGridLayout(minimumWidth: minimumWidth, spacing: Spacing.space3) { content }
  }
}

struct ShadowStatisticGridLayout: Layout {
  let minimumWidth: CGFloat
  let spacing: CGFloat

  func columns(for width: CGFloat, count: Int) -> Int {
    guard width.isFinite, count > 0 else { return max(count, 1) }
    var columns = min(max(Int((width + spacing) / (minimumWidth + spacing)), 1), count)
    while columns > 1 && count % columns == 1 { columns -= 1 }
    return columns
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard !subviews.isEmpty else { return .zero }
    let width = proposal.width ?? CGFloat(subviews.count) * minimumWidth + CGFloat(subviews.count - 1) * spacing
    let columns = columns(for: width, count: subviews.count)
    let heights = rowHeights(subviews: subviews, width: width, columns: columns)
    return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard !subviews.isEmpty else { return }
    let columns = columns(for: bounds.width, count: subviews.count)
    let columnWidth = (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    let heights = rowHeights(subviews: subviews, width: bounds.width, columns: columns)
    var y = bounds.minY
    for (row, height) in heights.enumerated() {
      for column in 0..<columns {
        let index = row * columns + column
        guard index < subviews.count else { break }
        let x = bounds.minX + (columnWidth + spacing) * CGFloat(column)
        subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: columnWidth, height: height))
      }
      y += height + spacing
    }
  }

  private func rowHeights(subviews: Subviews, width: CGFloat, columns: Int) -> [CGFloat] {
    let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    return stride(from: 0, to: subviews.count, by: columns).map { start in
      subviews[start..<min(start + columns, subviews.count)].map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0
    }
  }
}
