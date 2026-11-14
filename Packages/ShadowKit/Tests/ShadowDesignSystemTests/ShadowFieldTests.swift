import SwiftUI
import Testing

@testable import ShadowDesignSystem

@Suite("Field metrics")
struct ShadowFieldMetricsTests {
  @Test("should use a 44pt radius-xl field on touch and a 28pt radius-md field on Mac")
  func heights() {
    let touch = ShadowFieldMetrics(density: .touch)
    let compact = ShadowFieldMetrics(density: .compact)
    #expect(touch.minHeight == ShadowMetrics.controlTouchMd)
    #expect(touch.cornerRadius == Radius.xl)
    #expect(compact.minHeight == ShadowMetrics.controlMacMd)
    #expect(compact.cornerRadius == Radius.md)
  }

  @Test("should draw search fields as capsules on touch only")
  func searchShape() {
    #expect(ShadowFieldMetrics(density: .touch, kind: .search).cornerRadius == Radius.full)
    #expect(ShadowFieldMetrics(density: .compact, kind: .search).cornerRadius == Radius.md)
  }

  @Test("should keep the native bezel for plain Mac text fields only")
  func nativeBezel() {
    #expect(ShadowFieldMetrics(density: .compact, kind: .text).usesNativeBezel)
    #expect(!ShadowFieldMetrics(density: .compact, kind: .search).usesNativeBezel)
    #expect(!ShadowFieldMetrics(density: .compact, kind: .multiline).usesNativeBezel)
    #expect(!ShadowFieldMetrics(density: .touch, kind: .text).usesNativeBezel)
  }

  @Test("should make multiline fields taller than single-line fields", arguments: ShadowDensity.allCases)
  func multiline(density: ShadowDensity) {
    #expect(ShadowFieldMetrics(density: density, kind: .multiline).minHeight > ShadowFieldMetrics(density: density, kind: .text).minHeight)
  }
}

@Suite("Field phase")
struct ShadowFieldPhaseTests {
  @Test("should derive the phase from focus and validity", arguments: [(false, false), (true, false), (false, true), (true, true)])
  func derived(isFocused: Bool, isInvalid: Bool) {
    let phase = ShadowFieldPhase(isFocused: isFocused, isInvalid: isInvalid)
    #expect(phase.isFocused == isFocused)
    #expect(phase.isInvalid == isInvalid)
  }

  @Test("should show a halo in every phase except idle")
  func halo() {
    #expect(!ShadowFieldPhase.idle.showsHalo)
    #expect(ShadowFieldPhase.allCases.filter(\.showsHalo).count == 3)
  }
}

@Suite("Character count")
struct ShadowCharacterCountTests {
  @Test("should report remaining characters and the over-limit state")
  func limit() {
    #expect(ShadowCharacterCount(count: 112, limit: 600).remaining == 488)
    #expect(!ShadowCharacterCount(count: 600, limit: 600).isOverLimit)
    #expect(ShadowCharacterCount(count: 601, limit: 600).isOverLimit)
  }

  @Test("should never be over the limit when there is none")
  func unlimited() {
    #expect(!ShadowCharacterCount(count: 10_000).isOverLimit)
    #expect(ShadowCharacterCount(count: 3).remaining == nil)
  }

  @Test("should count grapheme clusters, not scalars")
  func graphemes() {
    #expect(ShadowCharacterCount(text: "👩‍👩‍👧‍👦é", limit: 5).count == 2)
  }

  @Test("should clamp negative input to zero")
  func negative() {
    #expect(ShadowCharacterCount(count: -4, limit: -1).count == 0)
    #expect(ShadowCharacterCount(count: -4, limit: -1).limit == 0)
  }
}

@Suite("Stepper and transfers")
struct ShadowInputLogicTests {
  @Test("should clamp typed values into the stepper range")
  func clamp() {
    #expect(ShadowStepper.clamped(12, in: 1...7) == 7)
    #expect(ShadowStepper.clamped(-3, in: 1...7) == 1)
    #expect(ShadowStepper.clamped(5, in: 1...7) == 5)
  }

  @Test("should clamp upload progress and round the percentage")
  func transfer() {
    #expect(ShadowTransferState.uploading(progress: 1.4).fraction == 1)
    #expect(ShadowTransferState.uploading(progress: -0.2).fraction == 0)
    #expect(ShadowTransferState.uploading(progress: 0.625).percent == 63)
    #expect(ShadowTransferState.queued.fraction == nil)
    #expect(ShadowTransferState.done.percent == 100)
  }

  @Test("should treat only queued and uploading as active")
  func active() {
    #expect(ShadowTransferState.queued.isActive)
    #expect(ShadowTransferState.uploading(progress: 0.1).isActive)
    #expect(!ShadowTransferState.done.isActive)
    #expect(!ShadowTransferState.failed.isActive)
  }
}
