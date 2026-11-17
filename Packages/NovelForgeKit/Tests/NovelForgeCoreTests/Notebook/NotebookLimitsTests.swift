import Foundation
import ShadowStore
import Testing

@testable import NovelForgeCore

// apps/novel-forge-server/src/modules/ledger/ledger.dto.ts:68-106
@Suite("Notebook limits")
struct NotebookLimitsTests {
  private let novel = NotebookFixture.novel

  @Test func shouldPublishTheReferenceLimits() {
    let limits: [Int] = [NotebookLimits.statement, NotebookLimits.why, NotebookLimits.writerLine, NotebookLimits.rejectedAlternatives, NotebookLimits.reason]
    #expect(limits == [4000, 4000, 1000, 20, 4000])
  }

  @Test func shouldAcceptTextAtEachLimitAndRefuseOneUnitMore() async throws {
    let store = try await NotebookFixture.store()
    let novel = novel
    let atLimit = AuthorNotebookEntry(
      kind: .direction, topic: "tone", statement: String(repeating: "a", count: NotebookLimits.statement), why: String(repeating: "b", count: NotebookLimits.why))
    let id = try await NotebookFixture.attempt(store) { transaction throws(NotebookError) in try Notebook.recordByAuthor(atLimit, novel: novel, in: &transaction).id }.get()

    let longStatement = AuthorNotebookEntry(kind: .direction, topic: "tone", statement: String(repeating: "😀", count: NotebookLimits.statement / 2) + "a")
    let refused = try await NotebookFixture.attempt(store) { transaction throws(NotebookError) in try Notebook.recordByAuthor(longStatement, novel: novel, in: &transaction) }
    #expect(refused.failure?.errorDescription == NotebookError.tooLong(field: "statement", limit: NotebookLimits.statement).errorDescription)

    let longLine = NotebookRewrite(statement: "Quiet", writerLine: String(repeating: "c", count: NotebookLimits.writerLine + 1))
    let rewrite = try await NotebookFixture.attempt(store) { transaction throws(NotebookError) in
      try Notebook.supersedeByAuthor(id, rewrite: longLine, novel: novel, in: &transaction)
    }
    #expect(rewrite.failure?.errorDescription == NotebookError.tooLong(field: "writerLine", limit: NotebookLimits.writerLine).errorDescription)

    let longReason = String(repeating: "d", count: NotebookLimits.reason + 1)
    let withdrawal = try await NotebookFixture.attempt(store) { transaction throws(NotebookError) in try Notebook.withdraw(id, reason: longReason, novel: novel, in: &transaction) }
    #expect(withdrawal.failure?.errorDescription == NotebookError.tooLong(field: "reason", limit: NotebookLimits.reason).errorDescription)
  }
}
