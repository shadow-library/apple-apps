import Foundation
import GRDB
import ShadowCore
import ShadowStore

public struct ChatProposalDetail: Sendable, Equatable {
  public let state: ProposalState
  public let entries: [ProposalEntryRow]
}

public struct ChatProposal: ReadModel {
  public let proposal: Derived<ChatProposalDetail?>
  public let faults: [ReadFault]

  private static let tables = [ProposalState.databaseTableName, ProposalEntryRow.databaseTableName]

  public static func load(_ proposal: UUID, in transaction: ReadTransaction) throws(StoreError) -> ChatProposal {
    let report = try ChatReadFaults(novel: nil, subject: NovelForgeKey.proposal(proposal), reading: tables, in: transaction)
    let detail = try report.section(tables) { () throws(StoreError) -> ChatProposalDetail? in
      try transaction.query { database in
        guard let state = try ProposalState.filter(Column("proposal") == proposal).fetchOne(database) else { return nil }
        let entries = try ProposalEntryRow.filter(Column("proposal") == proposal).order(Column("op")).fetchAll(database)
        return ChatProposalDetail(state: state, entries: entries)
      }
    }
    return ChatProposal(proposal: detail, faults: report.relevant)
  }
}

/// The novel's proposals whose merged decision is pending, oldest staged first, a card this version cannot read included; a proposal whose card is absent
/// or names no readable novel gets no row. apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:877 counts pending rows.
public struct ChatPendingProposals: ReadModel {
  public let proposals: Derived<[ProposalState]>
  public let faults: [ReadFault]

  private static let tables = [ProposalState.databaseTableName]

  public static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> ChatPendingProposals {
    let report = try ReadFaults(novel: novel, reading: tables, in: transaction)
    let proposals = try report.section(tables) { () throws(StoreError) -> [ProposalState] in
      let rows = try transaction.query { database in
        try ProposalState.filter(Column("novel") == novel && Column("decision") == ProposalDecision.pending.rawValue).fetchAll(database)
      }
      return rows.sorted { $0.staged == $1.staged ? $0.ref < $1.ref : $0.staged < $1.staged }
    }
    return ChatPendingProposals(proposals: proposals, faults: report.relevant)
  }

  public var count: Derived<Int> { proposals.map(\.count) }
}
