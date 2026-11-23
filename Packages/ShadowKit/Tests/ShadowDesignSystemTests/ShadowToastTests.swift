import Foundation
import SwiftUI
import Testing

@testable import ShadowDesignSystem

@Suite("Toast queue")
struct ShadowToastQueueTests {
  private func toast(_ id: String) -> ShadowToast {
    ShadowToast("Saved to your library", id: id)
  }

  @Test("should show the first toast immediately")
  func showsFirst() {
    var queue = ShadowToastQueue()
    let isShown = queue.enqueue(toast("a"))
    #expect(isShown)
    #expect(queue.current?.id == "a")
    #expect(queue.pending.isEmpty)
  }

  @Test("should queue later toasts behind the current one in order")
  func queuesInOrder() {
    var queue = ShadowToastQueue()
    queue.enqueue(toast("a"))
    queue.enqueue(toast("b"))
    queue.enqueue(toast("c"))
    #expect(queue.current?.id == "a")
    #expect(queue.pending.map(\.id) == ["b", "c"])
  }

  @Test("should leave a gap after dismissing the current toast until it advances")
  func dismissThenAdvance() {
    var queue = ShadowToastQueue()
    queue.enqueue(toast("a"))
    queue.enqueue(toast("b"))
    let wasCurrent = queue.dismiss(id: "a")
    #expect(wasCurrent)
    #expect(queue.current == nil)
    #expect(queue.pending.map(\.id) == ["b"])
    let next = queue.advance()
    #expect(next?.id == "b")
    #expect(queue.current?.id == "b")
    #expect(queue.pending.isEmpty)
  }

  @Test("should keep the order when a toast arrives during the gap")
  func arrivesDuringGap() {
    var queue = ShadowToastQueue()
    queue.enqueue(toast("a"))
    queue.enqueue(toast("b"))
    queue.dismiss(id: "a")
    queue.enqueue(toast("c"))
    #expect(queue.current == nil)
    let next = queue.advance()
    #expect(next?.id == "b")
    #expect(queue.pending.map(\.id) == ["c"])
  }

  @Test("should not advance while a toast is showing")
  func advanceWhileShowing() {
    var queue = ShadowToastQueue()
    queue.enqueue(toast("a"))
    queue.enqueue(toast("b"))
    let next = queue.advance()
    #expect(next == nil)
    #expect(queue.current?.id == "a")
  }

  @Test("should remove a pending toast without touching the current one")
  func dismissPending() {
    var queue = ShadowToastQueue()
    queue.enqueue(toast("a"))
    queue.enqueue(toast("b"))
    let wasCurrent = queue.dismiss(id: "b")
    #expect(!wasCurrent)
    #expect(queue.current?.id == "a")
    #expect(queue.pending.isEmpty)
  }

  @Test("should ignore a toast whose id is already showing or queued")
  func ignoresDuplicates() {
    var queue = ShadowToastQueue()
    queue.enqueue(toast("offline"))
    queue.enqueue(toast("saved"))
    let addedOffline = queue.enqueue(toast("offline"))
    #expect(!addedOffline)
    let addedSaved = queue.enqueue(toast("saved"))
    #expect(!addedSaved)
    #expect(queue.pending.map(\.id) == ["saved"])
  }

  @Test("should empty the queue")
  func removeAll() {
    var queue = ShadowToastQueue()
    queue.enqueue(toast("a"))
    queue.enqueue(toast("b"))
    queue.removeAll()
    #expect(queue.isEmpty)
    let next = queue.advance()
    #expect(next == nil)
  }
}

@Suite("Toast timing")
struct ShadowToastTimingTests {
  @Test("should show short messages for the four-second minimum")
  func shortMessage() {
    #expect(ShadowToastTiming.duration(characterCount: 21, hasAction: false, requested: .automatic, isVoiceOverRunning: false) == .seconds(4))
    #expect(ShadowToastTiming.duration(characterCount: 0, hasAction: false, requested: .automatic, isVoiceOverRunning: false) == .seconds(4))
  }

  @Test("should scale with text length up to the maximum")
  func scalesWithLength() {
    let medium = ShadowToastTiming.duration(characterCount: 75, hasAction: false, requested: .automatic, isVoiceOverRunning: false)
    let long = ShadowToastTiming.duration(characterCount: 600, hasAction: false, requested: .automatic, isVoiceOverRunning: false)
    #expect(medium == .seconds(7))
    #expect(long == ShadowToastTiming.maximum)
  }

  @Test("should give a toast with an action more time to reach it")
  func actionMinimum() {
    #expect(ShadowToastTiming.duration(characterCount: 16, hasAction: true, requested: .automatic, isVoiceOverRunning: false) == .seconds(6))
  }

  @Test("should double the time while VoiceOver is running")
  func voiceOver() {
    #expect(ShadowToastTiming.duration(characterCount: 21, hasAction: false, requested: .automatic, isVoiceOverRunning: true) == .seconds(8))
    #expect(ShadowToastTiming.duration(characterCount: 0, hasAction: false, requested: .seconds(3), isVoiceOverRunning: true) == .seconds(6))
  }

  @Test("should respect an explicit duration with a one-second floor")
  func explicit() {
    #expect(ShadowToastTiming.duration(characterCount: 400, hasAction: false, requested: .seconds(2.5), isVoiceOverRunning: false) == .seconds(2.5))
    #expect(ShadowToastTiming.duration(characterCount: 0, hasAction: false, requested: .seconds(0.1), isVoiceOverRunning: false) == .seconds(1))
    #expect(ShadowToastTiming.duration(characterCount: 0, hasAction: false, requested: .seconds(.infinity), isVoiceOverRunning: false) == nil)
  }

  @Test("should never auto-dismiss a persistent toast")
  func persistent() {
    #expect(ShadowToastTiming.duration(characterCount: 10, hasAction: false, requested: .persistent, isVoiceOverRunning: false) == nil)
    #expect(ShadowToastTiming.duration(characterCount: 10, hasAction: true, requested: .persistent, isVoiceOverRunning: true) == nil)
  }

  @Test("should announce the message and the action title")
  func announcement() {
    let toast = ShadowToast("Chapter deleted", action: ShadowToastButton("Undo") {})
    #expect(toast.announcement == "Chapter deleted, Undo")
    #expect(ShadowToast("Saved to your library").announcement == "Saved to your library")
  }

  @Test("should resolve the automatic placement per density")
  func placement() {
    #expect(ShadowToastPlacement.automatic.edge(for: .touch) == .top)
    #expect(ShadowToastPlacement.automatic.edge(for: .compact) == .bottom)
    #expect(ShadowToastPlacement.bottom.edge(for: .touch) == .bottom)
    #expect(ShadowToastPlacement.top.edge(for: .compact) == .top)
  }
}

@Suite("Toast countdown")
struct ShadowToastCountdownTests {
  private let start = ContinuousClock.now

  @Test("should run from the start with a deadline")
  func runs() {
    let countdown = ShadowToastCountdown(duration: .seconds(4), startingAt: start)
    #expect(countdown.isRunning)
    #expect(countdown.deadline == start + .seconds(4))
    #expect(countdown.remaining(at: start + .seconds(1)) == .seconds(3))
    #expect(countdown.remaining(at: start + .seconds(9)) == .zero)
  }

  @Test("should freeze the remaining time while paused")
  func pauses() {
    var countdown = ShadowToastCountdown(duration: .seconds(6), startingAt: start)
    countdown.pause(.hover, at: start + .seconds(1))
    #expect(!countdown.isRunning)
    #expect(countdown.deadline == nil)
    #expect(countdown.remaining(at: start + .seconds(30)) == .seconds(5))
    countdown.resume(.hover, at: start + .seconds(30))
    #expect(countdown.deadline == start + .seconds(35))
  }

  @Test("should stay paused until every reason clears")
  func multipleReasons() {
    var countdown = ShadowToastCountdown(duration: .seconds(6), startingAt: start)
    countdown.pause(.hover, at: start + .seconds(1))
    countdown.pause(.focus, at: start + .seconds(2))
    countdown.resume(.hover, at: start + .seconds(3))
    #expect(!countdown.isRunning)
    countdown.resume(.focus, at: start + .seconds(4))
    #expect(countdown.deadline == start + .seconds(9))
  }

  @Test("should ignore a resume for a reason that never paused it")
  func unmatchedResume() {
    var countdown = ShadowToastCountdown(duration: .seconds(4), startingAt: start)
    countdown.resume(.drag, at: start + .seconds(2))
    #expect(countdown.deadline == start + .seconds(4))
  }

  @Test("should leave a grace period after resuming near the end")
  func resumeGrace() {
    var countdown = ShadowToastCountdown(duration: .seconds(4), startingAt: start)
    countdown.pause(.drag, at: start + .milliseconds(3_900))
    countdown.resume(.drag, at: start + .seconds(10))
    #expect(countdown.deadline == start + .seconds(10) + ShadowToastTiming.resumeGrace)
  }
}

@Suite("Toast center")
@MainActor
struct ShadowToastCenterTests {
  @Test("should hand off to the next toast after the current one is dismissed")
  func handoff() async {
    let center = ShadowToastCenter()
    center.show(ShadowToast("Saved to your library", id: "saved"))
    center.show(ShadowToast("Chapter deleted", id: "deleted"))
    #expect(center.current?.id == "saved")
    center.dismiss(id: "saved")
    #expect(center.current == nil)
    await center.handoffSettled()
    #expect(center.current?.id == "deleted")
  }

  @Test("should clear everything at once")
  func dismissAll() {
    let center = ShadowToastCenter()
    center.show(ShadowToast("Saved to your library"))
    center.show(ShadowToast("Chapter deleted"))
    center.dismissAll()
    #expect(center.queue.isEmpty)
  }
}

@Suite("Toast anchor")
struct ShadowToastAnchorTests {
  @Test("should push a presenter at the window top below the status bar")
  func belowStatusBar() {
    #expect(ShadowToastAnchor.topInset(windowSafeTop: 62, presenterMinY: 0) == 62)
  }

  @Test("should add nothing when the presenter already starts below the status bar")
  func belowSafeArea() {
    #expect(ShadowToastAnchor.topInset(windowSafeTop: 62, presenterMinY: 120) == 0)
    #expect(ShadowToastAnchor.topInset(windowSafeTop: 62, presenterMinY: 40) == 22)
  }
}
