import Foundation
import ShadowCore
import ShadowStore

/// apps/novel-forge-server/src/modules/bible/volume/volume-action.registrar.ts:17-24 over `Volumes.markGoalMet`, which finds the active volume again inside
/// this transaction (volume.service.ts:101, VOL_003), so a volume another change completed since the card was staged is refused.
enum AdvanceVolumeExecutor: ProposalActionExecutor {
  static func execute(_ action: ProposalAction, in transaction: inout WriteTransaction) throws(ApplyError) -> String {
    guard case .actionAdvanceVolume(let advance) = action.op.operation else { throw .noHandler(action.op.type) }
    let novel = action.novel
    let volumes = try handlerStore { () throws(StoreError) in try VolumeRecord.listing(novel: novel, in: transaction) }
    if volumes.unreadable > 0 { throw .refused(.unreadableReferences(kind: "volume", count: volumes.unreadable)) }
    let outcome = try handlerDomain { () throws(DomainError) in try Volumes.markGoalMet(novel: novel, volume: advance.volumeKey, in: &transaction) }
    guard let activated = outcome.activated else { return "volume \(outcome.completed)'s goal is met — no later volume is planned yet" }
    return "volume \(outcome.completed)'s goal is met — volume \(activated) is now active"
  }
}
