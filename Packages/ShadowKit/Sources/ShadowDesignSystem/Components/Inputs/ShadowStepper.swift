import SwiftUI

public struct ShadowStepper: View {
  private let title: LocalizedStringKey
  @Binding private var value: Int
  private let range: ClosedRange<Int>
  private let step: Int
  @Environment(\.isEnabled) private var isEnabled

  public init(_ title: LocalizedStringKey, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1) {
    self.title = title
    _value = value
    self.range = range
    self.step = step
  }

  nonisolated public static func clamped(_ value: Int, in range: ClosedRange<Int>) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
  }

  public var body: some View {
    #if os(macOS)
      LabeledContent(title) {
        HStack(spacing: Spacing.space1) {
          TextField(title, value: clampedValue, format: .number)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: Spacing.space10 * 2)
          Stepper(title, value: $value, in: range, step: step)
            .labelsHidden()
        }
      }
    #else
      HStack(spacing: Spacing.space3) {
        Text(title)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(value, format: .number)
          .monospacedDigit()
          .foregroundStyle(ShadowColor.textSecondary)
        Stepper(title, value: $value, in: range, step: step)
          .labelsHidden()
          .fixedSize()
          .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
      }
      .accessibilityRepresentation {
        Stepper(title, value: $value, in: range, step: step)
          .accessibilityValue(Text(value, format: .number))
      }
    #endif
  }

  private var clampedValue: Binding<Int> {
    Binding(get: { value }, set: { value = Self.clamped($0, in: range) })
  }
}
