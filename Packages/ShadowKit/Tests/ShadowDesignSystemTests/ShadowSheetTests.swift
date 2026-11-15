import SwiftUI
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

@Suite("Fitted detents")
struct ShadowFittedDetentsTests {
  @Test("should start at medium until the content is measured")
  func unmeasured() {
    #expect(ShadowFittedDetents.detents(contentHeight: nil) == [.medium])
  }

  @Test("should fit the measured height, rounded up")
  func measured() {
    #expect(ShadowFittedDetents.detents(contentHeight: 211.2) == [.height(212)])
  }

  @Test("should add the navigation bar height above the content")
  func withBar() {
    #expect(ShadowFittedDetents.detents(contentHeight: 300, barHeight: 55.5) == [.height(356)])
  }
}
