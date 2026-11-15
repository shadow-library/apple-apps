import SwiftUI

extension EnvironmentValues {
  @Entry var shadowPreviewRatingHover: Int?
}

extension View {
  @_spi(Preview) public func shadowPreviewRatingHover(_ value: Int?) -> some View {
    environment(\.shadowPreviewRatingHover, value)
  }
}

public struct ShadowRating: View {
  private enum Mode {
    case input(Binding<Int>)
    case display(Double, count: Text?, showsValue: Bool)
  }

  private let label: LocalizedStringKey
  private let mode: Mode
  private let scale: ShadowRatingScale
  private let valueDescription: (Double) -> Text

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.controlSize) private var controlSize
  @Environment(\.layoutDirection) private var layoutDirection
  @Environment(\.shadowPreviewRatingHover) private var previewHover
  @State private var hover: Int?

  public init(_ label: LocalizedStringKey, value: Binding<Int>, maximum: Int = 5, valueDescription: @escaping (Int) -> Text) {
    self.label = label
    mode = .input(value)
    scale = ShadowRatingScale(maximum: maximum)
    self.valueDescription = { valueDescription(Int($0)) }
  }

  public init(
    _ label: LocalizedStringKey,
    rating: Double,
    maximum: Int = 5,
    count: Text? = nil,
    showsValue: Bool = false,
    valueDescription: @escaping (Double) -> Text
  ) {
    self.label = label
    mode = .display(rating, count: count, showsValue: showsValue)
    scale = ShadowRatingScale(maximum: maximum)
    self.valueDescription = valueDescription
  }

  private var size: ShadowControlSize { ShadowControlSize(controlSize) }
  private var isInput: Bool { if case .input = mode { true } else { false } }

  private var value: Double {
    switch mode {
    case .input(let binding): Double(scale.clamped(binding.wrappedValue))
    case .display(let rating, _, _): scale.clamped(rating)
    }
  }

  private var shownValue: Double {
    guard isInput, isEnabled, let preview = previewHover ?? hover else { return value }
    return Double(preview)
  }

  private var textStyle: ShadowTextStyle {
    switch size {
    case .small: .footnote
    case .medium: .body
    case .large: .title2
    }
  }

  private var spacing: CGFloat {
    switch size {
    case .small: Spacing.space05
    case .medium, .large: Spacing.space1
    }
  }

  public var body: some View {
    HStack(spacing: Spacing.space2) {
      stars
      summary
    }
    .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
  }

  @ViewBuilder
  private var stars: some View {
    let row = HStack(spacing: spacing) {
      ForEach(0..<scale.maximum, id: \.self) { index in
        let fill = scale.fill(at: index, for: shownValue)
        Image(systemName: fill.systemImage)
          .foregroundStyle(fill == .empty ? ShadowColor.textTertiary : ShadowColor.warningSolid)
          .opacity(scale.isPreviewed(at: index, committed: value, shown: shownValue) ? ShadowRatingScale.previewOpacity : 1)
      }
    }
    .shadowFont(textStyle)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(label))
    .accessibilityValue(valueDescription(value))

    if case .input(let binding) = mode {
      row
        .frame(minHeight: ShadowDensity.current == .touch && size != .small ? ShadowMetrics.tapTarget : nil)
        .contentShape(.rect)
        .overlay { gestureSurface(binding) }
        .focusable(isEnabled)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
          keyStep(press.key).map { step(binding, by: $0) } == nil ? .ignored : .handled
        }
        .accessibilityAdjustableAction { direction in
          switch direction {
          case .increment: step(binding, by: 1)
          case .decrement: step(binding, by: -1)
          @unknown default: break
          }
        }
    } else {
      row
    }
  }

  private func gestureSurface(_ binding: Binding<Int>) -> some View {
    GeometryReader { proxy in
      Color.clear
        .contentShape(.rect)
        .onTapGesture(coordinateSpace: .local) { location in
          set(binding, at: location.x, width: proxy.size.width)
        }
        .simultaneousGesture(
          DragGesture(minimumDistance: Spacing.space2)
            .onChanged { gesture in
              guard abs(gesture.translation.width) > abs(gesture.translation.height) else { return }
              set(binding, at: gesture.location.x, width: proxy.size.width)
            }
        )
        .onContinuousHover { phase in
          switch phase {
          case .active(let location): hover = isEnabled ? scale.value(atOffset: offset(location.x, width: proxy.size.width), width: proxy.size.width) : nil
          case .ended: hover = nil
          }
        }
    }
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var summary: some View {
    if case .display(let rating, let count, let showsValue) = mode, showsValue || count != nil {
      HStack(spacing: Spacing.space1) {
        if showsValue {
          Text(scale.clamped(rating), format: .number.precision(.fractionLength(1)))
            .foregroundStyle(ShadowColor.textPrimary)
        }
        if let count {
          count
        }
      }
      .shadowFont(textStyle == .title2 ? .body : textStyle)
      .monospacedDigit()
      .foregroundStyle(ShadowColor.textSecondary)
      .accessibilityHidden(true)
    }
  }

  private func set(_ binding: Binding<Int>, at x: CGFloat, width: CGFloat) {
    guard isEnabled else { return }
    let newValue = scale.value(atOffset: offset(x, width: width), width: width)
    if binding.wrappedValue != newValue { binding.wrappedValue = newValue }
  }

  private func offset(_ x: CGFloat, width: CGFloat) -> CGFloat {
    layoutDirection == .rightToLeft ? width - x : x
  }

  private func keyStep(_ key: KeyEquivalent) -> Int? {
    let forward = layoutDirection == .rightToLeft ? KeyEquivalent.leftArrow : .rightArrow
    let backward = layoutDirection == .rightToLeft ? KeyEquivalent.rightArrow : .leftArrow
    switch key {
    case forward, .upArrow: return 1
    case backward, .downArrow: return -1
    default: return nil
    }
  }

  private func step(_ binding: Binding<Int>, by delta: Int) {
    binding.wrappedValue = scale.stepped(binding.wrappedValue, by: delta)
  }
}
