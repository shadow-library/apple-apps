import Foundation

/// proposal-apply.service.ts:173-181: a card's selected passage rewrites of one chapter apply as one step, run at the first of them, whose change holds the
/// undo and the states for all; every later one is carried by it, recorded applied with no undo of its own, and is undone or redone with it.
enum CarriedRewrites {
  /// For each rewrite recorded with no undo of its own, the rewrites of its chapter before it that hold one. `recorded` lists the indexes recorded applied or
  /// reverted across every applier, `holdingUndo` those of them holding an undo. One carrier is its leader; more than one means concurrent appliers grouped
  /// the chapter differently, so which of them carried it is unknown. An op this version cannot read is neither carrier nor carried.
  static func carriers<Op: StoredChangeOp>(of ops: [Op], recorded: [Int], holdingUndo: Set<Int>) -> [Int: [Int]] {
    var holders = [Int: [Int]]()
    var carriers = [Int: [Int]]()
    for index in Set(recorded).sorted() where ops.indices.contains(index) {
      guard case .draftRewritePassage(let rewrite)? = ops[index].op?.operation else { continue }
      if holdingUndo.contains(index) {
        holders[rewrite.chapter, default: []].append(index)
      } else if let found = holders[rewrite.chapter] {
        carriers[index] = found
      }
    }
    return carriers
  }

  /// How a carried rewrite stands given its carriers' states: as its one leader stands; with several, applied while all stand applied, reverted once all
  /// are reverted, and `uncertain` in any other mix, so it never makes a card read reverted.
  static func standing<State: Equatable>(of carriers: [State], applied: State, reverted: State, uncertain: State) -> State {
    if carriers.count == 1, let leader = carriers.first { return leader }
    if !carriers.isEmpty, carriers.allSatisfy({ $0 == applied }) { return applied }
    if !carriers.isEmpty, carriers.allSatisfy({ $0 == reverted }) { return reverted }
    return uncertain
  }
}
