import Foundation
import ShadowCore
import ShadowStore
import ShadowText

/// A draft as the apply will find it once `DraftHandlers.settleWorkingCopies` commits this device's working copy, read without writing it: staging and a
/// rejection's anchor must describe the prose the author sees, but committing the copy would add a synced revision per staged card and move the editor's
/// base. A copy over a moved head is kept aside by that settle, and one over a final chapter is left alone, so neither is read through.
enum DraftReadThrough {
  static func content(novel: UUID, chapter: Int, over head: DraftHead, in transaction: borrowing WriteTransaction) throws(ApplyError) -> DraftContent {
    let copy: DraftWorkingCopy?
    do throws(StoreError) {
      copy = try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: transaction.database)
    } catch {
      throw .store(error)
    }
    guard let copy, copy.base.utf8.elementsEqual(head.revision.utf8) else { return head.content }
    if try DraftHandlers.reading(chapter, { () throws(DomainError) in try transaction.isFinal(novel: novel, chapter: chapter) }) { return head.content }
    return copy.content
  }

  /// The live drafts of `chapters` as read through this device's working copies; a missing, removed or unreadable draft has none.
  static func records(_ chapters: [Int], novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> [Int: DraftRecord] {
    var records = [Int: DraftRecord]()
    for chapter in Set(chapters).sorted() where chapter >= 1 {
      let presence: DraftPresence
      do throws(ApplyError) {
        presence = try DraftHandlers.presence(novel: novel, chapter: chapter, in: transaction)
      } catch {
        if case .unreadable = error { continue }
        throw error
      }
      guard case .live(let head) = presence else { continue }
      var record = head.record
      record.content = try content(novel: novel, chapter: chapter, over: head, in: transaction)
      records[chapter] = record
    }
    return records
  }

  /// `ArtifactStateLoader.states` with each live draft's state taken from its read-through content; the draft's content hash covers title, body and summary
  /// only, so it equals the state the apply reads after its settle.
  static func states(refs: [String], novel: UUID, drafts: [Int: DraftRecord], in transaction: borrowing WriteTransaction) throws(StoreError) -> [JSString: ArtifactState] {
    var states = try ArtifactStateLoader.states(refs: refs, novel: novel, in: transaction)
    for ref in refs {
      guard case .draft(let chapter)? = ArtifactRef(ref), let draft = drafts[chapter], let state = states[JSString(ref)], state.exists, !state.isUnreadable else { continue }
      states[JSString(ref)] = ArtifactState(exists: true, revision: nil, contentHash: ArtifactSubject.draft(draft).contentHash)
    }
    return states
  }

  static func draftChapters(of refs: [String]) -> [Int] {
    refs.compactMap { ref in
      guard case .draft(let chapter)? = ArtifactRef(ref) else { return nil }
      return chapter
    }
  }
}
