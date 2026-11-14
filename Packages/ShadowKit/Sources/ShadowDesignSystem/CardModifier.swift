import SwiftUI

struct CardModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(Spacing.space4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial, in: .rect(cornerRadius: Radius.section))
  }
}

extension View {
  public func shadowCard() -> some View {
    modifier(CardModifier())
  }
}
