import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:817: the Notebook section reads the active ledger without its lapsed rejections
enum ChatContextLedger {
  struct Notebook: Equatable, Sendable {
    let entries: [ChatPackLedgerEntry]
    /// False when an active entry could not be read, or is of a kind or author this version does not know: the readable ones are kept.
    let complete: Bool
  }

  /// The active entries the Notebook shows, oldest first, without the rejections whose scope has lapsed. A rejection is kept, never dropped, when what it is judged
  /// against cannot be read: the volumes (`volumes` nil) or a record it is anchored to.
  static func notebook(novel: UUID, volumes: [VolumeItem]?, in transaction: ReadTransaction) throws(StoreError) -> Notebook {
    let listed = try NotebookContents.entries(NotebookQuery(novel: novel), in: transaction)
    let records = listed.entries.map(\.record)
    let kept = try withoutLapsed(records, novel: novel, volumes: volumes, in: transaction)
    let entries = kept.compactMap(ledgerEntry)
    return Notebook(entries: entries, complete: listed.unreadable == 0 && records.allSatisfy { ledgerEntry($0) != nil })
  }

  private static func withoutLapsed(
    _ records: [NotebookEntryRecord], novel: UUID, volumes: [VolumeItem]?, in transaction: ReadTransaction
  ) throws(StoreError) -> [NotebookEntryRecord] {
    guard let volumes else { return records }
    let rejections = records.map(rejection)
    let refs = rejectionStateRefs(for: rejections.filter { $0.ideaId?.isEmpty == false && $0.rejectionScope != nil })
    let states = try ArtifactStateLoader.states(refs: refs, novel: novel, in: transaction)
    let kept = withoutLapsedRejections(
      Array(zip(records, rejections)), rejection: { keptWhenUnreadable($0.1, states: states) },
      volumes: volumes.map { RejectionVolume(volumeKey: $0.record.volume, ordinal: $0.record.ordinal, state: $0.state) }, artifactStates: states)
    return kept.map(\.0)
  }

  static func rejection(_ record: NotebookEntryRecord) -> IdeaRejectionEntry {
    IdeaRejectionEntry(
      ideaId: record.idea, rejectionScope: record.rejectionScope?.known, rejectionAnchor: record.rejectionAnchor.flatMap { RejectionAnchor(json: OrderedJSON($0)) })
  }

  private static func keptWhenUnreadable(_ entry: IdeaRejectionEntry, states: [JSString: ArtifactState]) -> IdeaRejectionEntry {
    guard entry.rejectionScope == .notThisVersion, case .states(let anchored)? = entry.rejectionAnchor,
      anchored.contains(where: { states[JSString($0.ref)]?.isUnreadable == true })
    else { return entry }
    return IdeaRejectionEntry(ideaId: entry.ideaId, rejectionScope: .never, rejectionAnchor: nil)
  }

  private static func ledgerEntry(_ record: NotebookEntryRecord) -> ChatPackLedgerEntry? {
    guard let kind = record.entryKind.known, let decidedBy = record.decidedBy.known else { return nil }
    return ChatPackLedgerEntry(
      kind: kind, topic: record.topic, statement: record.statement, why: record.why, rejectedAlternatives: record.rejectedAlternatives, writerLine: record.writerLine,
      decidedBy: decidedBy, ideaId: record.idea, rejectionScope: record.rejectionScope?.known)
  }
}
