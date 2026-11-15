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
