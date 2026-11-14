import Testing

@testable import ShadowDesignSystem

@Suite("Glass variants")
struct ShadowGlassTests {
  @Test("should start non-interactive and opt in with interactive()", arguments: ShadowGlass.Kind.allCases)
  func interactive(kind: ShadowGlass.Kind) {
    let glass = [ShadowGlass.regular, .dense, .prominent, .clear].first { $0.kind == kind }
    #expect(glass?.isInteractive == false)
    #expect(glass?.interactive().isInteractive == true)
    #expect(glass?.interactive().interactive(false) == glass)
  }
}
