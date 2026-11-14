import Testing

@testable import ShadowDesignSystem

@Suite("ShadowColumn")
struct ShadowColumnTests {
  @Test("should size the sidebar from the density's sidebar token")
  func sidebarIdeal() {
    #expect(ShadowColumn.sidebar.width(for: .touch).ideal == ShadowMetrics.sidebarIpad)
    #expect(ShadowColumn.sidebar.width(for: .compact).ideal == ShadowMetrics.sidebarMac)
  }

  @Test("should size the inspector from the inspector token on every density")
  func inspectorIdeal() {
    for density in ShadowDensity.allCases {
      #expect(ShadowColumn.inspector.width(for: density).ideal == ShadowMetrics.inspector)
    }
  }

  @Test("should keep every ideal width within its bounds", arguments: ShadowColumn.allCases)
  func boundsContainIdeal(column: ShadowColumn) {
    for density in ShadowDensity.allCases {
      let width = column.width(for: density)
      #expect(width.minimum <= width.ideal)
      #expect(width.ideal <= width.maximum)
    }
  }

  @Test("should keep the touch inspector fixed at its token width")
  func touchInspectorFixed() {
    let width = ShadowColumn.inspector.width(for: .touch)
    #expect(width.minimum == width.maximum)
  }
}

@Suite("ShadowSidebarBadge")
struct ShadowSidebarBadgeTests {
  @Test("should show a plain count as the native badge only")
  func count() {
    #expect(ShadowSidebarBadge.count(42).count == 42)
    #expect(ShadowSidebarBadge.count(42).alertCount == nil)
  }

  @Test("should show an alert as a count badge only")
  func alert() {
    #expect(ShadowSidebarBadge.alert(2).alertCount == 2)
    #expect(ShadowSidebarBadge.alert(2).count == nil)
  }

  @Test("should hide zero and negative values", arguments: [0, -3])
  func hidesEmpty(value: Int) {
    #expect(ShadowSidebarBadge.count(value).count == nil)
    #expect(ShadowSidebarBadge.alert(value).alertCount == nil)
  }
}
