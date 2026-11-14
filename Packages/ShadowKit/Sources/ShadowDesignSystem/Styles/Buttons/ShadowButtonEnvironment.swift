import SwiftUI

extension EnvironmentValues {
  @Entry var shadowButtonIsLoading = false
  @Entry var shadowPreviewInteraction: ShadowButtonInteraction?
}

extension View {
  public func shadowLoading(_ isLoading: Bool) -> some View {
    environment(\.shadowButtonIsLoading, isLoading)
      .disabled(isLoading)
  }

  @_spi(Preview) public func shadowPreviewInteraction(_ interaction: ShadowButtonInteraction?) -> some View {
    environment(\.shadowPreviewInteraction, interaction)
  }
}
