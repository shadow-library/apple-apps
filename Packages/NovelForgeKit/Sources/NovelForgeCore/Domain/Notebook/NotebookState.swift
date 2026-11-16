import Foundation

public struct NotebookEntryState: Hashable, Sendable {
  public let successor: UUID?
  public let withdrawal: UUID?

  public static let active = NotebookEntryState(successor: nil, withdrawal: nil)

  public init(successor: UUID?, withdrawal: UUID?) {
    self.successor = successor
    self.withdrawal = withdrawal
  }

  public var status: LedgerEntryStatus {
    if withdrawal != nil { return .withdrawn }
    return successor == nil ? .active : .superseded
  }
}

// ledger.ts:71-88; the latest of several concurrent supersedes succeeds the target and each earlier sibling, and a withdrawal labels over a successor
public enum NotebookResolution {
  public static func resolve(entries: [AppendedEntry<NotebookEntryRecord>], withdrawals: [AppendedEntry<NotebookWithdrawalRecord>]) -> [UUID: NotebookEntryState] {
    let byId = Dictionary(entries.map { ($0.record.id, $0) }) { first, _ in first }
    var children = [UUID: [AppendedEntry<NotebookEntryRecord>]]()
    for entry in entries {
      guard let target = entry.record.supersedes, target != entry.record.id, byId[target]?.record.novel == entry.record.novel else { continue }
      children[target, default: []].append(entry)
    }

    var successors = [UUID: AppendedEntry<NotebookEntryRecord>]()
    func claim(_ id: UUID, by claimant: AppendedEntry<NotebookEntryRecord>) {
      if let current = successors[id], !NotebookEntryRecord.chronologically(current, claimant) { return }
      successors[id] = claimant
    }
    for (target, group) in children {
      let ordered = group.sorted(by: NotebookEntryRecord.chronologically)
      guard let latest = ordered.last else { continue }
      claim(target, by: latest)
      for earlier in ordered.dropLast() { claim(earlier.record.id, by: latest) }
    }

    let withdrawn = NotebookEntryRecord.withdrawals(of: entries.map(\.record), among: withdrawals)
    return Dictionary(uniqueKeysWithValues: byId.keys.map { ($0, NotebookEntryState(successor: successors[$0]?.record.id, withdrawal: withdrawn[$0]?.record.id)) })
  }
}
