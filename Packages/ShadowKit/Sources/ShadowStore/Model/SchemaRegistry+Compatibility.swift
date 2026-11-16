extension SchemaRegistry {
  public func incompatibilities(with earlier: SchemaRegistry) -> [String] {
    var problems = [String]()
    if version < earlier.version { problems.append("version \(version) is lower than the earlier version \(earlier.version)") }
    for old in earlier.schemas {
      guard let new = self[old.kind] else {
        problems.append("kind \(old.kind) was removed")
        continue
      }
      problems += Self.incompatibilities(of: new, with: old)
    }
    return problems
  }

  private static func incompatibilities(of new: EntitySchema, with old: EntitySchema) -> [String] {
    let kind = old.kind
    guard new.shape.name == old.shape.name else { return ["kind \(kind) changed shape from \(old.shape.name) to \(new.shape.name)"] }
    var problems = [String]()
    if new.syncClass != old.syncClass { problems.append("kind \(kind) changed sync class from \(old.syncClass.rawValue) to \(new.syncClass.rawValue)") }
    for (name, oldRule) in old.shape.fields.sorted(by: { ExactString($0.key) < ExactString($1.key) }) {
      guard let newRule = new.rule(forField: name) else {
        problems.append("field \(kind).\(name) was removed")
        continue
      }
      guard newRule.canonicalBytes != oldRule.canonicalBytes, !oldRule.isExtended(by: newRule) else { continue }
      problems.append("field \(kind).\(name) changed rule from \(oldRule.summary) to \(newRule.summary)")
    }
    for mark in old.shape.marks.sorted(by: { ExactString($0) < ExactString($1) }) where !new.declaresMark(mark) { problems.append("mark \(kind).\(mark) was removed") }
    if case .revisioned(_, _, let oldRetention) = old.shape, case .revisioned(_, _, let newRetention) = new.shape {
      switch (oldRetention, newRetention) {
      case (.keepNewest(let before), .keepNewest(let after)) where after > before:
        problems.append("retention of \(kind) grew from the newest \(before) to the newest \(after)")
      case (.keepNewest(let before), .keepAll):
        problems.append("retention of \(kind) changed from the newest \(before) to keeping all")
      default:
        break
      }
    }
    return problems
  }
}
