import Testing

@testable import ShadowDesignSystem

@Suite("Sheet dismiss guard")
struct ShadowDismissGuardTests {
  @Test("should dismiss straight away without unsaved changes")
  func clean() {
    var guardState = ShadowDismissGuard()
    #expect(guardState.allowsInteractiveDismiss)
    let dismissed = guardState.requestDismiss()
    #expect(dismissed)
    #expect(!guardState.isConfirmingDiscard)
  }

  @Test("should block swipe-to-dismiss and ask before discarding changes")
  func dirty() {
    var guardState = ShadowDismissGuard(hasUnsavedChanges: true)
    #expect(!guardState.allowsInteractiveDismiss)
    let dismissed = guardState.requestDismiss()
    #expect(!dismissed)
    #expect(guardState.isConfirmingDiscard)
  }

  @Test("should clear the changes when they are discarded")
  func discard() {
    var guardState = ShadowDismissGuard(hasUnsavedChanges: true)
    _ = guardState.requestDismiss()
    guardState.discard()
    #expect(!guardState.isConfirmingDiscard)
    #expect(guardState.allowsInteractiveDismiss)
    let dismissedAfterDiscard = guardState.requestDismiss()
    #expect(dismissedAfterDiscard)
  }

  @Test("should keep the changes when people keep editing")
  func keepEditing() {
    var guardState = ShadowDismissGuard(hasUnsavedChanges: true)
    _ = guardState.requestDismiss()
    guardState.keepEditing()
    #expect(!guardState.isConfirmingDiscard)
    #expect(guardState.hasUnsavedChanges)
    #expect(!guardState.allowsInteractiveDismiss)
  }

  @Test("should allow dismissing once the changes are saved")
  func saved() {
    var guardState = ShadowDismissGuard(hasUnsavedChanges: true)
    guardState.hasUnsavedChanges = false
    #expect(guardState.allowsInteractiveDismiss)
    let dismissed = guardState.requestDismiss()
    #expect(dismissed)
  }
}
