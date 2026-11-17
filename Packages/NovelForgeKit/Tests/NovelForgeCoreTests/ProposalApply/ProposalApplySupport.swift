import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

enum ApplyWorld {
  static let maraMotive = #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","motivation":"She wants the lamp."}"#
  static let kael = #"{"op":"entity.upsert","entityKey":"kael","type":"character","name":"Kael"}"#
  static let premise = #"{"op":"premise.update","premise":"A fencer keeps a lamp."}"#
  static let missingVolume = #"{"op":"volume.remove","volumeKey":"volume_9"}"#
  static let approve3 = #"{"op":"action.approve_draft","chapter":3}"#
  static let finalize3 = #"{"op":"action.finalize","upTo":3}"#

  static func advance(_ volume: String) -> String {
    #"{"op":"action.advance_volume","volumeKey":"\#(volume)"}"#
  }
}

extension ChapterBook {
  func context(automatic: Bool = false, sources: [OpSource]? = nil, unrestricted: Bool = false) -> ProposalApplyContext {
    ProposalApplyContext(novel: novel, now: clock.now, automatic: automatic, sources: sources, unrestrictedAvailable: unrestricted)
  }

  func apply(_ id: UUID, _ selection: ApplySelection = .whole, context: ProposalApplyContext? = nil) async throws -> ProposalApplyOutcome {
    let outcome = try await store.applyProposal(id, selection: selection, context: context ?? self.context())
    try await Projection.expectNoFaults(in: store)
    return outcome
  }

  func applied(_ id: UUID, _ selection: ApplySelection = .whole, context: ProposalApplyContext? = nil) async throws -> [ProposalChangeOutcome] {
    guard case .applied(let outcomes) = try await apply(id, selection, context: context) else { throw ProposalApplyTestError.conflicted }
    return outcomes
  }

  func applyError(_ id: UUID, _ selection: ApplySelection = .whole, context: ProposalApplyContext? = nil) async -> ProposalApplyError? {
    do {
      _ = try await store.applyProposal(id, selection: selection, context: context ?? self.context())
      return nil
    } catch {
      return error
    }
  }

  func changes(_ id: UUID) async throws -> [ProposalChangeEntry] {
    let proposal = try await proposal(id)
    return try await store.read { try ProposalChangeRecord.changes(of: proposal, in: $0) }
  }

  func change(_ id: UUID, _ index: Int) async throws -> ProposalChangeRecord {
    guard case .recorded(let change) = try await changes(id)[index] else { throw ProposalApplyTestError.unrecorded(index) }
    return change
  }

  func premise() async throws -> String? {
    let novel = novel
    return try await store.read { try NovelRecord.read(NovelForgeKey.novel(novel), in: $0).entry?.record.premise }
  }

  func volume(_ key: String, ordinal: Int) async throws {
    let novel = novel
    try await run { try Volumes.create(novel: novel, volume: key, ordinal: ordinal, title: key, in: &$0) }
  }

  func activeVolume() async throws -> String? {
    let novel = novel
    return try await store.read { NovelForgeCore.activeVolume(of: try VolumeRecord.listing(novel: novel, in: $0).live) }
  }

  /// A revision written as another device's edit would arrive: no working copy, no base.
  func reviseElsewhere(_ chapter: Int, _ body: String) async throws {
    let novel = novel
    try await run { transaction in
      let content = DraftContent(body: body, summary: "It turns.", source: .known(.handEdited), generator: .known(.human))
      _ = try DraftRecord.revise(try DraftRecord.ref(novel: novel, chapter: chapter), content, in: &transaction)
    }
  }
}

enum ProposalApplyTestError: Error {
  case conflicted
  case unrecorded(Int)
}
