import SwiftUI
import Testing

@testable import ShadowDesignSystem

@MainActor
@Suite("Identifier text")
struct ShadowIdentifierTextTests {
  private func height(of identifier: String, width: CGFloat) -> CGFloat {
    let view = ShadowIdentifierText(identifier)
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: width, alignment: .leading)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    return CGFloat(renderer.cgImage?.height ?? 0)
  }

  @Test("should keep a long identifier on one line instead of wrapping it")
  func staysOnOneLine() {
    let narrow = height(of: "mail.shadowlibrary.app", width: 80)
    let wide = height(of: "mail.shadowlibrary.app", width: 400)
    #expect(narrow > 0)
    #expect(narrow == wide)
  }
}
