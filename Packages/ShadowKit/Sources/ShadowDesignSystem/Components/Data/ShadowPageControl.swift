import SwiftUI

public struct ShadowPageControl: View {
  private let count: Int
  private let selection: Binding<Int>
  private let hidesForSinglePage: Bool
  private let label: Text
  private let value: (ShadowStepsPosition) -> Text

  @ScaledMetric(relativeTo: .body) private var dot = 7

  public init(count: Int, selection: Binding<Int>, hidesForSinglePage: Bool = true, label: Text, value: @escaping (ShadowStepsPosition) -> Text) {
    self.count = max(count, 0)
    self.selection = selection
    self.hidesForSinglePage = hidesForSinglePage
    self.label = label
    self.value = value
  }

  private var current: Int { ShadowStepsPosition.clamped(selection.wrappedValue, count: count) }

  public var body: some View {
    if count > (hidesForSinglePage ? 1 : 0) {
      HStack(spacing: 0) {
        ForEach(0..<count, id: \.self) { index in
          Circle()
            .fill(index == current ? ShadowColor.textPrimary : ShadowColor.borderStrong)
            .frame(width: dot, height: dot)
            .frame(width: Spacing.space5, height: ShadowDensity.current == .touch ? ShadowMetrics.tapTarget : Spacing.space6)
            .contentShape(.rect)
            .onTapGesture { selection.wrappedValue = index }
        }
      }
      .shadowAnimation(.fast, value: current)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label)
      .accessibilityValue(value(ShadowStepsPosition(index: current, count: count)))
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: selection.wrappedValue = min(current + 1, count - 1)
        case .decrement: selection.wrappedValue = max(current - 1, 0)
        @unknown default: break
        }
      }
    }
  }
}
