extension VaultState {
  public func retained(registry: SchemaRegistry) -> VaultState {
    var copy = self
    for (ref, state) in entities {
      guard case .revisioned(let revisioned) = state, case .revisioned(_, _, .keepNewest(let count)) = registry[ref.kind]?.shape else { continue }
      copy.entities[ref] = .revisioned(revisioned.keepingNewest(count))
    }
    return copy
  }
}

extension RevisionedState {
  func keepingNewest(_ count: Int) -> RevisionedState {
    let newest = revisions.sorted { lhs, rhs in
      guard lhs.value.generation == rhs.value.generation else { return lhs.value.generation > rhs.value.generation }
      return lhs.key > rhs.key
    }
    let kept = Set(newest.prefix(max(count, 0)).map(\.key)).union(namedRevisions)
    return with(revisions: revisions.filter { kept.contains($0.key) })
  }
}
