import SwiftUI

nonisolated public enum ShadowStepState: Hashable, Sendable {
  case completed
  case current
  case upcoming

  public init(index: Int, current: Int) {
    if index < current {
      self = .completed
    } else if index == current {
      self = .current
    } else {
      self = .upcoming
    }
  }

  public var isReached: Bool { self != .upcoming }
}

nonisolated public struct ShadowStepsPosition: Hashable, Sendable {
  public let number: Int
  public let count: Int

  public init(index: Int, count: Int) {
    self.count = max(count, 0)
    number = Self.clamped(index, count: count) + 1
  }

  public var index: Int { number - 1 }

  public static func clamped(_ index: Int, count: Int) -> Int {
    min(max(index, 0), max(count - 1, 0))
  }
}

nonisolated public enum ShadowStepsStyle: Hashable, Sendable {
  case bars
  case numbered
}

public struct ShadowSteps: View {
  private let titles: [Text]
  private let current: Int
  private let style: ShadowStepsStyle
  private let position: (ShadowStepsPosition) -> Text
  private let stateLabel: ((ShadowStepState) -> Text)?

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  public init(
    current: Int, titles: [Text], style: ShadowStepsStyle = .bars, position: @escaping (ShadowStepsPosition) -> Text,
    stateLabel: ((ShadowStepState) -> Text)? = nil
  ) {
    self.titles = titles
    self.current = ShadowStepsPosition.clamped(current, count: titles.count)
    self.style = style
    self.position = position
    self.stateLabel = stateLabel
  }

  private var isVertical: Bool { horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize }
  private var currentPosition: ShadowStepsPosition { ShadowStepsPosition(index: current, count: titles.count) }

  private var listsEveryStep: Bool { style == .numbered && stateLabel != nil }

  public var body: some View {
    if !titles.isEmpty {
      if listsEveryStep {
        content.shadowAnimation(.normal, value: current).accessibilityElement(children: .contain)
      } else {
        content
          .shadowAnimation(.normal, value: current)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text("\(position(currentPosition)), \(titles[current])"))
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch style {
    case .bars: ShadowStepBars(titles: titles, current: current, caption: Text("\(position(currentPosition)) · \(titles[current])"))
    case .numbered: ShadowStepNumbers(titles: titles, current: current, isVertical: isVertical, position: position, stateLabel: stateLabel)
    }
  }
}

private struct ShadowStepBars: View {
  let titles: [Text]
  let current: Int
  let caption: Text

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(spacing: Spacing.space1) {
        ForEach(titles.indices, id: \.self) { index in
          Capsule()
            .fill(ShadowStepState(index: index, current: current).isReached ? ShadowColor.accent : ShadowColor.fillTrack)
            .frame(height: Spacing.space1)
        }
      }
      caption
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textSecondary)
    }
  }
}

private struct ShadowStepNumbers: View {
  let titles: [Text]
  let current: Int
  let isVertical: Bool
  let position: (ShadowStepsPosition) -> Text
  let stateLabel: ((ShadowStepState) -> Text)?

  @ScaledMetric(relativeTo: .body) private var diameter = ShadowDensity.current == .touch ? 28 : 22

  var body: some View {
    if isVertical {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(titles.indices, id: \.self) { index in
          HStack(alignment: .top, spacing: Spacing.space3) {
            VStack(spacing: Spacing.space1) {
              ShadowStepMarker(number: index + 1, state: ShadowStepState(index: index, current: current), diameter: diameter)
              if index < titles.count - 1 { connector(isFilled: index < current).frame(width: 2).frame(minHeight: Spacing.space4) }
            }
            title(index).padding(.top, (diameter - Spacing.space5) / 2)
          }
          .modifier(accessibility(index))
        }
      }
    } else {
      HStack(alignment: .top, spacing: 0) {
        ForEach(titles.indices, id: \.self) { index in
          VStack(spacing: Spacing.space2) {
            HStack(spacing: 0) {
              connector(isFilled: index <= current).frame(height: 2).opacity(index == 0 ? 0 : 1)
              ShadowStepMarker(number: index + 1, state: ShadowStepState(index: index, current: current), diameter: diameter)
              connector(isFilled: index < current).frame(height: 2).opacity(index == titles.count - 1 ? 0 : 1)
            }
            title(index).multilineTextAlignment(.center).padding(.horizontal, Spacing.space1)
          }
          .frame(maxWidth: .infinity)
          .modifier(accessibility(index))
        }
      }
    }
  }

  private func accessibility(_ index: Int) -> ShadowStepAccessibility {
    let state = ShadowStepState(index: index, current: current)
    return ShadowStepAccessibility(
      label: stateLabel.map { _ in Text("\(position(ShadowStepsPosition(index: index, count: titles.count))), \(titles[index])") }, value: stateLabel?(state),
      isCurrent: state == .current)
  }

  private func connector(isFilled: Bool) -> some View {
    Capsule().fill(isFilled ? ShadowColor.accent : ShadowColor.fillTrack)
  }

  private func title(_ index: Int) -> some View {
    let state = ShadowStepState(index: index, current: current)
    return titles[index]
      .shadowFont(.subheadline)
      .fontWeight(state == .current ? .semibold : .regular)
      .foregroundStyle(state == .upcoming ? ShadowColor.textSecondary : ShadowColor.textPrimary)
  }
}

private struct ShadowStepAccessibility: ViewModifier {
  let label: Text?
  let value: Text?
  let isCurrent: Bool

  func body(content: Content) -> some View {
    if let label, let value {
      content
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    } else {
      content
    }
  }
}

private struct ShadowStepMarker: View {
  let number: Int
  let state: ShadowStepState
  let diameter: CGFloat

  var body: some View {
    ZStack {
      Circle().fill(fill)
      Circle().strokeBorder(stroke, lineWidth: state == .upcoming ? 2 : 0)
      glyph
    }
    .frame(width: diameter, height: diameter)
  }

  private var fill: Color { state == .upcoming ? .clear : ShadowColor.accent }
  private var stroke: Color { ShadowColor.borderStrong }

  @ViewBuilder
  private var glyph: some View {
    if state == .completed {
      Image(systemName: "checkmark")
        .font(Font.shadow(.caption).weight(.bold))
        .foregroundStyle(ShadowColor.onAccent)
    } else {
      Text(verbatim: number.formatted())
        .font(Font.shadow(.caption).weight(.semibold).monospacedDigit())
        .foregroundStyle(state == .current ? ShadowColor.onAccent : ShadowColor.textSecondary)
    }
  }
}
