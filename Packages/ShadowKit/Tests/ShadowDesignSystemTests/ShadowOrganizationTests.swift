import SwiftUI
import Testing

@testable import ShadowDesignSystem

@MainActor
@Suite("Organization switcher")
struct ShadowOrganizationSwitcherTests {
  private let organizations = [
    ShadowOrganization(id: "a", name: "Shadow Library", detail: "Pulse"),
    ShadowOrganization(id: "b", name: "Synapse Labs", detail: "Synapse"),
  ]

  @Test("should select the organization with the matching id")
  func selectsMatch() {
    #expect(ShadowOrganization.selected("b", in: organizations)?.name == "Synapse Labs")
  }

  @Test("should fall back to the first organization when the id is unknown")
  func fallsBack() {
    #expect(ShadowOrganization.selected("x", in: organizations)?.id == "a")
  }

  @Test("should select nothing when there are no organizations")
  func selectsNothing() {
    #expect(ShadowOrganization.selected("a", in: []) == nil)
  }
}

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
