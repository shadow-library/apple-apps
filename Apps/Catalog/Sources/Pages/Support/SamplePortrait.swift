import ShadowDesignSystem
import SwiftUI

@MainActor
enum SamplePortrait {
  static func image(_ color: Color, symbol: String = "person.fill") -> Image {
    let content = ZStack {
      LinearGradient(colors: [color, color.mix(with: .black, by: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
      Image(systemName: symbol)
        .font(.system(size: 64, weight: .regular))
        .foregroundStyle(.white.opacity(0.85))
    }
    .frame(width: 128, height: 128)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let cgImage = renderer.cgImage else { return Image(systemName: symbol) }
    return Image(decorative: cgImage, scale: 2)
  }
}
