import Foundation
import ShadowCore
import ShadowStore
import ShadowText

// apps/novel-forge-server/src/modules/refinement/chat.dto.ts:256
private let passageHashPattern = builtInPattern("^[0-9a-f]{64}$")

/// A live draft as the author sees it on this device: its head, read through this device's working copy as `DraftReadThrough` reads it, with the identity,
/// generation and earlier revisions a passage anchors to.
struct ChatTurnDraft: Sendable {
  let record: DraftRecord
  let identity: String
  let generation: Int
  let revisions: [RevisionEntry<DraftContent>]

  var passageDraft: PassageDraft {
    PassageDraft(id: identity, chapter: record.chapter, revision: generation, saveSeq: 0, body: record.content.body, isolated: record.content.isolated)
  }

  /// passage-context.ts:60: the body of the revision the author read, by its generation; the newest when branches share one.
  func body(at generation: Int) -> String? {
    revisions.first { $0.generation == Int64(generation) }?.body.body?.body
  }
}

enum ChatTurnDrafts {
  /// The DTO's member limits (chat.dto.ts:234-264), which the reference enforces before the turn runs; a quote's and a comment's length are counted in code
  /// points, as the schema validator counts them. The draft id is the native `DraftIdentity`, not the reference's digits.
  static func validate(_ passages: [ChatTurnPassage]) throws(ChatTurnError) {
    guard passages.count <= maxPassageContexts else { throw .tooManyPassages(limit: maxPassageContexts) }
    for (index, passage) in passages.enumerated() {
      let valid =
        passage.chapter >= 1 && passage.revision >= 0 && (passage.saveSeq ?? 0) >= 0 && passage.start >= 0 && passage.end >= 1
        && passageHashPattern.test(passage.passageHash) && (1...maxPassageQuoteChars).contains(passage.quote.unicodeScalars.count)
        && passage.comment.unicodeScalars.count <= maxPassageCommentChars
      guard valid else { throw .invalidPassage(index: index) }
    }
  }

  /// The live drafts of `chapters`; a draft that is missing, removed or unreadable here has none, so a passage in it reads as changed (CHT_009).
  static func read(_ chapters: [Int], novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> [Int: ChatTurnDraft] {
    var drafts = [Int: ChatTurnDraft]()
    for chapter in Set(chapters).sorted() where chapter >= 1 {
      guard let ref = try? DraftRecord.ref(novel: novel, chapter: chapter) else { continue }
      let state = try transaction.state(of: ref, scope: .vault)
      guard case .readable(let entry) = DraftRecord.reading(state, of: ref), !entry.isRemoved, let identity = DraftIdentity.of(state),
        case .revisioned(let revisioned)? = state, let head = revisioned.headRevision, let generation = revisioned.revisions[ExactString(head)]?.generation,
        let revision = Int(exactly: generation), let history = DraftRecord.history(of: state, at: ref).history
      else { continue }
      var record = entry.record
      record.content = try readThrough(record.content, novel: novel, chapter: chapter, head: head, in: transaction)
      drafts[chapter] = ChatTurnDraft(record: record, identity: identity, generation: revision, revisions: history.revisions)
    }
    return drafts
  }

  /// passage-context.ts:92 over the drafts as this device reads them.
  static func resolve(_ passages: [ChatTurnPassage], drafts: [Int: ChatTurnDraft]) throws(ChatTurnError) -> [ChatPassageContext] {
    do throws(PassageContextError) {
      return try resolvePassageContexts(passages.map(\.input), drafts: drafts.values.map(\.passageDraft)) { draftId, revision in
        drafts.values.first { $0.identity.jsEquals(draftId) }?.body(at: revision)
      }
    } catch {
      throw .passage(code: error.code, chapter: error.chapter)
    }
  }

  /// The read-transaction twin of `DraftReadThrough.content`, which needs a write transaction; the two must read the same copy.
  /// The draft's head as the author sees it on this device: the working copy when it rests on that head, as `DraftReadThrough` reads it, since a revision
  /// is committed only every 600 s (orchestrator decision 6). A copy over a moved head or a final chapter is not read through.
  static func readThrough(_ content: DraftContent, novel: UUID, chapter: Int, head: String? = nil, in transaction: ReadTransaction) throws(StoreError) -> DraftContent {
    guard let copy = try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: transaction.database), let ref = try? DraftRecord.ref(novel: novel, chapter: chapter)
    else { return content }
    let current: String?
    if let head {
      current = head
    } else if case .revisioned(let state)? = try transaction.stateNamingRevisions(of: ref, scope: .vault) {
      current = state.headRevision
    } else {
      current = nil
    }
    guard let current, copy.base.utf8.elementsEqual(current.utf8), try !isFinal(novel: novel, chapter: chapter, in: transaction) else { return content }
    return copy.content
  }

  private static func isFinal(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws(StoreError) -> Bool {
    guard let ref = try? FinalChapterRecord.ref(novel: novel, chapter: chapter) else { return false }
    return FinalChapterRecord.reading(try transaction.state(of: ref, scope: .vault), of: ref) != .absent
  }
}
