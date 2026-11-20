import ShadowCore
import ShadowText

/// apps/novel-forge-server/src/modules/refinement/op-undo.ts:13-67: a change depends on another when it cannot stand without it (names a record only the other
/// created, or is a page owing its entity type) or wrote a record after it; undo and redo keep each record's changes a stack. An index whose stored op does
/// not validate never ran, so it is neither a dependent nor a prerequisite.
struct AppliedOpGraph: Sendable {
  private let ops: [ChangeOp?]
  private let graph: OpGraph
  private let compact: [Int: Int]
  private let position: [Int: Int]

  /// `order` lists the content indexes in the order the apply ran them; `existing` the refs that existed before it did.
  init(ops: [ChangeOp?], existing: Set<String>, order: [Int]) {
    let present = ops.enumerated().compactMap { index, op in op.map { (index: index, op: $0) } }
    self.ops = ops
    graph = OpGraph(ops: present.map(\.op), current: WritePolicyState(current: existing.sorted().map { (ref: $0, fields: OrderedJSONObject([])) }))
    compact = Dictionary(present.enumerated().map { ($1.index, $0) }) { first, _ in first }
    position = Dictionary(order.enumerated().map { ($1, $0) }) { first, _ in first }
  }

  /// proposal-revert.service.ts:224: a ref the baseline records as existing, readable or not, was not created by the apply.
  init(ops: [ChangeOp?], baseline: ArtifactStates, order: [Int]) {
    self.init(ops: ops, existing: Set(changeSetRefs(ops.compactMap { $0 }).filter { baseline[$0]?.exists == true }), order: order)
  }

  // op-undo.ts:32
  func dependents(_ index: Int, applied: [Int]) -> [Int] {
    var found = [Int]()
    var grew = true
    while grew {
      grew = false
      let dropped = [index] + found
      let kept = applied.filter { !dropped.contains($0) }
      for candidate in kept where stranded(candidate, dropped: dropped, kept: kept) || dropped.contains(where: { follows(candidate, $0) }) {
        found.append(candidate)
        grew = true
      }
    }
    return byPosition(found).reversed()
  }

  // op-undo.ts:48
  func prerequisites(_ index: Int, undone: [Int], applied: [Int]) -> [Int] {
    let kept = applied.filter { $0 != index } + [index]
    return byPosition(undone.filter { $0 != index && (stranded(index, dropped: [$0], kept: kept) || follows(index, $0)) })
  }

  private func stranded(_ index: Int, dropped: [Int], kept: [Int]) -> Bool {
    guard let at = compact[index] else { return false }
    return graph.stranded(at, dropped: dropped.compactMap { compact[$0] }, kept: kept.compactMap { compact[$0] })
  }

  // op-undo.ts:54
  private func follows(_ later: Int, _ earlier: Int) -> Bool {
    let refs = Set(self.refs(earlier).map { JSString($0) })
    return self.refs(later).contains { refs.contains(JSString($0)) } && at(later) > at(earlier)
  }

  private func refs(_ index: Int) -> [String] {
    guard ops.indices.contains(index), let op = ops[index] else { return [] }
    return changeSetRefs([op])
  }

  private func at(_ index: Int) -> Int {
    position[index] ?? -1
  }

  private func byPosition(_ indexes: [Int]) -> [Int] {
    indexes.enumerated().sorted { (at($0.element), $0.offset) < (at($1.element), $1.offset) }.map(\.element)
  }
}
