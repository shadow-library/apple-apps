private let authorBacked: Set<CardReason> = [.justDiscussing, .manualMode, .heldForReview, .dependsOnCard]

struct IdeaFilterResult: Sendable, Equatable {
  let split: ChangeSetSplit
  let dropped: [String]
}

// apps/novel-forge-server/src/modules/refinement/idea-filter.ts:21
private func isFilterable(_ split: ChangeSetSplit, _ index: Int) -> Bool {
  guard split.dispositions.indices.contains(index), split.ops.indices.contains(index), !isActionOp(split.ops[index]) else { return false }
  let disposition = split.dispositions[index]
  switch disposition {
  case .direct(_, let source): return source == .idea
  case .card(_, let reason, _): return !authorBacked.contains(reason)
  }
}

// apps/novel-forge-server/src/modules/refinement/idea-filter.ts:31
private func requiredEntityTypes(_ op: ChangeOp) -> [EntityType] {
  guard case .bibleDocumentUpsert(let page) = op.operation, let body = page.body, !body.jsTrim().isEmpty else { return [] }
  return requiredEntityTypesForSlug(section: page.section.rawValue, slug: page.slug)
}

extension OpDisposition {
  fileprivate func moved(to index: Int) -> OpDisposition {
    switch self {
    case .direct(_, let source): .direct(index: index, source: source)
    case .card(_, let reason, let rule): .card(index: index, reason: reason, rule: rule)
    }
  }
}

// apps/novel-forge-server/src/modules/refinement/idea-filter.ts:36
struct OpGraph: Sendable {
  private let ops: [ChangeOp]
  private let current: WritePolicyState

  init(ops: [ChangeOp], current: WritePolicyState) {
    self.ops = ops
    self.current = current
  }

  // apps/novel-forge-server/src/modules/refinement/idea-filter.ts:44
  func leansOn(_ from: Int, _ to: Int) -> Bool {
    let created = Set(created([to]).map { JSString($0) })
    let type = entityTypes([to]).first
    return names(from).contains { created.contains(JSString($0)) } || (type.map { requiredEntityTypes(ops[from]).contains($0) } ?? false)
  }

  // apps/novel-forge-server/src/modules/refinement/idea-filter.ts:50
  func stranded(_ index: Int, dropped: [Int], kept: [Int]) -> Bool {
    let supplied = Set(created(kept).map { JSString($0) })
    let lost = Set(created(dropped).map { JSString($0) }).subtracting(supplied)
    if names(index).contains(where: { lost.contains(JSString($0)) }) { return true }
    let required = requiredEntityTypes(ops[index])
    if required.isEmpty { return false }
    let keptTypes = entityTypes(kept)
    let droppedTypes = entityTypes(dropped)
    return !required.contains(where: keptTypes.contains) && required.contains(where: droppedTypes.contains)
  }

  // apps/novel-forge-server/src/modules/refinement/idea-filter.ts:63
  private func created(_ indexes: [Int]) -> [String] {
    changeSetRefs(indexes.map { ops[$0] }).filter { !current.has($0) }
  }

  // apps/novel-forge-server/src/modules/refinement/idea-filter.ts:67
  private func names(_ index: Int) -> [String] {
    changeSetRefs([ops[index]]) + opReferences(ops[index])
  }

  // apps/novel-forge-server/src/modules/refinement/idea-filter.ts:71
  private func entityTypes(_ indexes: [Int]) -> [EntityType] {
    indexes.compactMap { index in
      guard case .entityUpsert(let entity) = ops[index].operation else { return nil }
      return entity.type
    }
  }
}

extension IdeaIdentity {
  static func filterableIdeaIds(_ split: ChangeSetSplit, with identity: IdeaIdentity? = shared) -> [String] {
    identity?.filterableIdeaIds(split) ?? []
  }

  static func dropRejectedIdeas(_ split: ChangeSetSplit, rejected: Set<JSString>, current: WritePolicyState, with identity: IdeaIdentity? = shared) -> IdeaFilterResult {
    identity?.dropRejectedIdeas(split, rejected: rejected, current: current) ?? IdeaFilterResult(split: split, dropped: [])
  }

  // apps/novel-forge-server/src/modules/refinement/idea-filter.ts:29
  func filterableIdeaIds(_ split: ChangeSetSplit) -> [String] {
    split.ops.indices.compactMap { index in isFilterable(split, index) ? ideaId(of: split.ops[index]) : nil }
  }

  // apps/novel-forge-server/src/modules/refinement/idea-filter.ts:79
  func dropRejectedIdeas(_ split: ChangeSetSplit, rejected: Set<JSString>, current: WritePolicyState) -> IdeaFilterResult {
    let indexes = Array(split.ops.indices)
    let rejectedIndexes = indexes.filter { isFilterable(split, $0) && rejected.contains(JSString(ideaId(of: split.ops[$0]))) }
    if rejectedIndexes.isEmpty { return IdeaFilterResult(split: split, dropped: []) }

    let graph = OpGraph(ops: split.ops, current: current)
    var needed = Set(indexes.filter { !isFilterable(split, $0) })
    var grew = true
    while grew {
      grew = false
      for candidate in indexes where !needed.contains(candidate) && needed.contains(where: { graph.leansOn($0, candidate) }) {
        needed.insert(candidate)
        grew = true
      }
    }

    var dropped = rejectedIndexes.filter { !needed.contains($0) }
    var droppedSet = Set(dropped)
    grew = !dropped.isEmpty
    while grew {
      grew = false
      let kept = indexes.filter { !droppedSet.contains($0) }
      for index in kept where !needed.contains(index) && graph.stranded(index, dropped: dropped, kept: kept) {
        dropped.append(index)
        droppedSet.insert(index)
        grew = true
      }
    }
    if dropped.isEmpty { return IdeaFilterResult(split: split, dropped: []) }

    let kept = indexes.filter { !droppedSet.contains($0) }
    let position = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })
    let ops = kept.map { split.ops[$0] }
    let dispositions = split.dispositions.compactMap { disposition in position[disposition.index].map { disposition.moved(to: $0) } }
    return IdeaFilterResult(
      split: ChangeSetSplit(
        ops: ops,
        direct: dispositions.filter { $0.side == .direct }.map { ops[$0.index] },
        cards: dispositions.filter { $0.side == .card }.map { ops[$0.index] },
        sources: dispositions.compactMap { disposition in
          guard case .direct(_, let source) = disposition else { return nil }
          return source
        },
        dispositions: dispositions,
        held: split.held
      ),
      dropped: dropped.map { ideaId(of: split.ops[$0]) }
    )
  }
}
