import ShadowDesignSystem
import SwiftUI

extension View {
  func fillingSurface() -> some View {
    frame(maxWidth: .infinity, maxHeight: .infinity).background(ShadowColor.surfaceApp)
  }
}
