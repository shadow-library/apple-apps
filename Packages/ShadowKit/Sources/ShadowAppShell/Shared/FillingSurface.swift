import ShadowDesignSystem
import SwiftUI

extension View {
  public func fillingSurface() -> some View {
    frame(maxWidth: .infinity, maxHeight: .infinity).background(ShadowColor.surfaceApp)
  }
}
