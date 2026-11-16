import Foundation
import ShadowCore
import ShadowStore

public struct NotebookEntry: Sendable, Equatable {
  public let record: NotebookEntryRecord
  public let clock: HLCTimestamp
  public let state: NotebookEntryState

  public var id: UUID { record.id }
  public var status: LedgerEntryStatus { state.status }
}

// apps/novel-forge-server/src/modules/ledger/ledger.types.ts:42
public struct NotebookFilter: Sendable, Equatable {
  public var kinds: [LedgerEntryKind]
  public var topics: [String]

  public init(kinds: [LedgerEntryKind] = [], topics: [String] = []) {
    self.kinds = kinds
    self.topics = topics
  }
}

// apps/novel-forge-server/src/modules/ledger/ledger-sections.ts:44
public struct NotebookSections: Sendable, Equatable {
  public struct PassedOver: Sendable, Equatable {
    public let alternative: String
    public let topic: String
  }

  public let decisions: [NotebookEntry]
  public let directions: [NotebookEntry]
  public let backlog: [NotebookEntry]
  public let rejected: [NotebookEntry]
  public let passedOver: [PassedOver]

  public init(of entries: [NotebookEntry]) {
    let shown = entries.filter { NotebookTopics.isVisibleInNotebook($0.record.topic) }
    let decided = shown.filter { Self.isDecided($0) }
    decisions = decided
    directions = shown.filter { $0.record.entryKind == .known(.direction) }
    backlog = shown.filter { $0.record.entryKind == .known(.backlog) }
    rejected = shown.filter { $0.record.entryKind == .known(.rejected) }
    passedOver = decided.flatMap { entry in entry.record.rejectedAlternatives.map { PassedOver(alternative: $0, topic: entry.record.topic) } }
  }

  private static func isDecided(_ entry: NotebookEntry) -> Bool {
    entry.record.entryKind == .known(.decision) || entry.record.entryKind == .known(.system)
  }
}

public struct NotebookLedger: Sendable, Equatable {
  public let entries: [NotebookEntry]
  public let unreadable: Int

  public init(entries: [NotebookEntry], unreadable: Int = 0) {
    self.entries = entries
    self.unreadable = unreadable
  }

  public static func load<Transaction: StateReading & ~Copyable>(novel: UUID, in transaction: borrowing Transaction) throws(StoreError) -> NotebookLedger {
    let listing = try NotebookEntryRecord.listing(novel: novel, in: transaction)
    let withdrawals = try NotebookWithdrawalRecord.listing(novel: novel, in: transaction).entries
    let states = NotebookResolution.resolve(entries: listing.entries, withdrawals: withdrawals)
    return NotebookLedger(
      entries: listing.entries.map { NotebookEntry(record: $0.record, clock: $0.clock, state: states[$0.record.id] ?? .active) }, unreadable: listing.unreadable)
  }

  public func entry(_ id: UUID) -> NotebookEntry? { entries.first { $0.id == id } }

  // ledger.service.ts:93, ledger-entries.ts:28
  public func active(matching filter: NotebookFilter = NotebookFilter()) -> [NotebookEntry] {
    entries.filter { $0.status == .active && Self.matches($0.record, filter) }
  }

  // ledger.controller.ts:24: an explicit topics filter opts back into the reserved topics
  public func notebook(matching filter: NotebookFilter = NotebookFilter()) -> [NotebookEntry] {
    let matching = active(matching: filter)
    return filter.topics.isEmpty ? matching.filter { NotebookTopics.isVisibleInNotebook($0.record.topic) } : matching
  }

  // ledger.service.ts:97
  public func history(topic: String) -> [NotebookEntry] {
    entries.filter { $0.record.topic.utf8.elementsEqual(topic.utf8) }
  }

  public func sections(matching filter: NotebookFilter = NotebookFilter()) -> NotebookSections {
    NotebookSections(of: active(matching: filter))
  }

  private static func matches(_ record: NotebookEntryRecord, _ filter: NotebookFilter) -> Bool {
    if !filter.kinds.isEmpty, !filter.kinds.contains(where: { record.entryKind == .known($0) }) { return false }
    return filter.topics.isEmpty || filter.topics.contains { NotebookTopics.matches(record.topic, pattern: $0) }
  }
}
