import Foundation

/// proposal-apply.service.ts:173-181: a card's selected passage rewrites of one chapter apply as one step, run at the first of them, whose change holds the
/// undo and the states for all; every later one is carried by it, recorded applied with no undo of its own, and is undone or redone with it.
enum CarriedRewrites {
  /// Each carried index of the selection, mapped to its leader: the first selected rewrite of its chapter, as `ApplyPlanner` groups them. An op this version
  /// cannot read is neither leader nor carried, as `ApplyPlanner` skips it.
  static func leaders<Op: StoredChangeOp>(of ops: [Op], selected: [Int]) -> [Int: Int] {
    var leaderOfChapter = [Int: Int]()
    var leaders = [Int: Int]()
    for index in Set(selected).sorted() where ops.indices.contains(index) {
      guard case .draftRewritePassage(let rewrite)? = ops[index].op?.operation else { continue }
      if let leader = leaderOfChapter[rewrite.chapter] { leaders[index] = leader } else { leaderOfChapter[rewrite.chapter] = index }
    }
    return leaders
  }
}
