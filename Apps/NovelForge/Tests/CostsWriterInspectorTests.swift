import Foundation
@_spi(Preview) import NovelForgeCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForge

@MainActor
@Suite("Writer inspector")
struct CostsWriterInspectorTests {
  private nonisolated static let walledOff = "Prose: walled off. This is an unrestricted chapter, so the messages it sent are not available here."

  private nonisolated static func summary(
    _ id: UUID = UUID(), revision: String = "r1", attempt: Int = 1, role: WriterAttemptRole = .draft, isolated: Bool = false
  ) -> WriterSnapshotSummary {
    WriterSnapshotSummary(
      id: id, chapter: 1, revision: revision, attempt: attempt, role: role, promptKey: "generation", promptVersion: "2.12.0",
      route: WriterSnapshotRoute(provider: "api.example.com", model: "model-a"), isolated: isolated, recordedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(attempt)))
  }

  private nonisolated static func view(_ summary: WriterSnapshotSummary, messages: [WriterSnapshotMessage]) -> WriterSnapshotView {
    WriterSnapshotView(summary: summary, messages: messages, keptBack: ["withheldForSecrecy": ["prose": 2]], planRevision: "plan-1", bibleHash: summary.isolated ? nil : "bible")
  }

  private struct Failure: Error {}

  @Test func shouldShowAStandardSnapshotsRequest() async throws {
    let standard = Self.summary()
    let sent = [WriterSnapshotMessage(role: "system", content: "You are the writer."), WriterSnapshotMessage(role: "user", content: "Write chapter 1.")]
    let model = WriterInspectorModel(reader: .init(attempts: { [standard] }, view: { _ in Self.view(standard, messages: sent) }))
    await model.load()

    let shown = try #require(model.detail.value ?? nil)
    #expect(shown.messages == sent && !shown.summary.isolated)
    #expect(model.run?.attempts.map(\.id) == [standard.id])
  }

  @Test func shouldWithholdAnIsolatedSnapshotsRequestAsTheCoreDoes() async throws {
    let isolated = Self.summary(isolated: true)
    let model = WriterInspectorModel(
      reader: .init(attempts: { [isolated] }, view: { _ in Self.view(isolated, messages: [WriterSnapshotMessage(role: "system", content: Self.walledOff)]) }))
    await model.load()

    let shown = try #require(model.detail.value ?? nil)
    #expect(shown.summary.isolated && shown.bibleHash == nil)
    #expect(shown.messages.map(\.content) == [Self.walledOff])
  }

  @Test func shouldReadAFaultedListOrSnapshotAsUnavailable() async {
    let broken = WriterInspectorModel(reader: .init(attempts: { throw Failure() }, view: { _ in nil }))
    await broken.load()
    guard case .failed = broken.runs else {
      Issue.record("expected a failed list")
      return
    }

    let attempt = Self.summary()
    let faulted = WriterInspectorModel(reader: .init(attempts: { [attempt] }, view: { _ in throw Failure() }))
    await faulted.load()
    guard case .failed = faulted.detail else {
      Issue.record("expected a failed snapshot")
      return
    }
  }

  @Test func shouldGroupAttemptsOfOneWritingCallAndKeepPassageRewritesApart() {
    let draft = Self.summary(revision: "r1", attempt: 1, role: .draft)
    let repair = Self.summary(revision: "r1", attempt: 2, role: .repair)
    let passage = Self.summary(revision: "r2", attempt: 1, role: .passage)
    let runs = WriterDisplay.runs([passage, repair, draft])

    #expect(runs.count == 2)
    #expect(runs.first { $0.attempts.contains { $0.role == .repair } }?.attempts.map(\.attempt) == [1, 2])
    #expect(runs.first { $0.role == .passage }?.attempts.map(\.id) == [passage.id])
  }

  @Test func shouldSayWhatWasKeptFromTheWriter() {
    let kept = WriterDisplay.keptBack(["withheldForSecrecy": ["prose": 2, "plan": 0], "omittedForBudget": [["key": "notes"], [:]]])
    #expect(kept.secrecy == ["2 passages withheld from earlier prose"])
    #expect(kept.budget == ["notes", "a section"])
    #expect(WriterDisplay.keptBack(.null) == WriterDisplay.KeptBack(secrecy: [], budget: []))
  }
}
