import Foundation
import ShadowStore

public enum NotesReading: Sendable, Equatable {
  case text(String)
  case unreadable
}

// apps/novel-forge-server/src/modules/notes/notes-store.service.ts:75: notes never written read as empty
public struct NovelNotes: ReadModel {
  public let notes: NotesReading

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> NovelNotes {
    switch try AuthorNotesRecord.readHead(AuthorNotesRecord.ref(novel: novel), in: transaction) {
    case .absent: NovelNotes(notes: .text(""))
    case .unreadable: NovelNotes(notes: .unreadable)
    case .readable(let entry): NovelNotes(notes: .text(entry.record.content.text))
    }
  }
}
