import SwiftUI

public struct ShadowButtonStyle: ButtonStyle {
  public enum Variant: Sendable, CaseIterable {
    case primary
    case secondary
    case destructive
  }

  @Environment(\.isEnabled) private var isEnabled
  private let variant: Variant

  public init(_ variant: Variant) {
    self.variant = variant
  }

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .padding(.vertical, Spacing.space2)
      .padding(.horizontal, Spacing.space4)
      .foregroundStyle(foreground)
      .background(background, in: .rect(cornerRadius: Radius.xl))
      .opacity(isEnabled ? 1 : 0.4)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.snappy(duration: 0.15), value: configuration.isPressed)
  }

  private var foreground: Color {
    switch variant {
    case .primary, .destructive: .white
    case .secondary: .accentColor
    }
  }

  private var background: Color {
    switch variant {
    case .primary: .accentColor
    case .secondary: .accentColor.opacity(0.15)
    case .destructive: .red
    }
  }
}

extension ButtonStyle where Self == ShadowButtonStyle {
  public static var shadowPrimary: ShadowButtonStyle { ShadowButtonStyle(.primary) }
  public static var shadowSecondary: ShadowButtonStyle { ShadowButtonStyle(.secondary) }
  public static var shadowDestructive: ShadowButtonStyle { ShadowButtonStyle(.destructive) }
}
