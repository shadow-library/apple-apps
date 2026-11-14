import SwiftUI

struct CardModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(Spacing.lg)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial, in: .rect(cornerRadius: CornerRadius.lg))
  }
}

extension View {
  public func shadowCard() -> some View {
    modifier(CardModifier())
  }
}
