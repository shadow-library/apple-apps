import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private let wordPool = ["Mira", "tide", "é", "😀", "a b", "x", "line\nbreak", "K"]
private let keyPool = ["v1", "vol_3", "mira", "lamp_rank_4", "é"]
private let ignoredMembers = ["toString", "constructor", "__proto__", "hasOwnProperty", "valueOf"]
private let arbitraryKeys =
  [
    "op", "chapter", "section", "slug", "body", "scope", "kind", "key", "label", "type", "anchor", "scenes", "unlock", "endingContract", "knowledgeContract", "toString", "x", "",
    "rationale", "someday",
  ]
  + OpType.allCases.map(\.rawValue)

private func object(_ pairs: [(String, OrderedJSON)]) -> OrderedJSON {
  .object(OrderedJSONObject(pairs.map { (key: $0.0, value: $0.1) }))
}

private func text(_ generator: inout SeededGenerator) -> OrderedJSON {
  .string(generator.pick(from: wordPool))
}

private func key(_ generator: inout SeededGenerator) -> OrderedJSON {
  .string(generator.pick(from: keyPool))
}

private func texts(_ generator: inout SeededGenerator, count: ClosedRange<Int> = 1...3) -> OrderedJSON {
  .array((0..<generator.int(in: count)).map { _ in text(&generator) })
}

private func positive(_ generator: inout SeededGenerator) -> OrderedJSON {
  .int(Int64(generator.int(in: 1...40)))
}

private func scenes(_ generator: inout SeededGenerator) -> OrderedJSON {
  .array(
    (0..<generator.int(in: 1...2)).map { _ in
      var pairs: [(String, OrderedJSON)] = [("summary", text(&generator))]
      if generator.chance(0.5) { pairs.append(("pov", generator.chance(0.3) ? .null : key(&generator))) }
      if generator.chance(0.3) { pairs.append(("estimatedWords", .int(Int64(generator.int(in: 1...2000))))) }
      return object(pairs)
    })
}

private func anchor(_ generator: inout SeededGenerator) -> OrderedJSON {
  let start = generator.int(in: 0...40)
  return object([
    ("draftId", .string("3")), ("revision", .int(1)), ("saveSeq", .int(0)), ("start", .int(Int64(start))), ("end", .int(Int64(start + generator.int(in: 1...20)))),
    ("passageHash", .string("h")), ("paragraph", .int(2)), ("contextBefore", text(&generator)), ("contextAfter", text(&generator)),
  ])
}

private func fieldValue(_ op: OpType, _ field: OpField, _ generator: inout SeededGenerator) -> OrderedJSON {
  switch field.name {
  case "section": return .string("plot")
  case "slug": return .string("escalation-map")
  case "type": return .string(generator.pick(from: EntityType.allCases).rawValue)
  case "writeMode": return .string(generator.pick(from: BriefWriteMode.allCases).rawValue)
  case "contentMode": return generator.chance(0.2) ? .null : .string(generator.pick(from: ContentMode.allCases).rawValue)
  case "scope": return .string(generator.pick(from: ValidationScope.allCases).rawValue)
  case "kind": return .string(op.rawValue.jsStartsWith("promise.") ? generator.pick(from: PromiseKind.allCases).rawValue : generator.pick(from: MilestoneKind.allCases).rawValue)
  case "status": return op == .promiseUpdate ? .string(generator.pick(from: PromiseOpStatus.allCases).rawValue) : text(&generator)
  case "milestoneKey", "key", "volumeKey", "entityKey", "factKey": return key(&generator)
  case "subjectEntityKey", "payoffMilestoneKey", "payoffVolumeKey": return generator.chance(0.25) ? .null : key(&generator)
  case "claimedMilestones": return generator.chance(0.2) ? .null : .array([key(&generator)])
  case "allowedClues": return generator.chance(0.2) ? .null : texts(&generator)
  case "revealChapter", "payoffWindow": return generator.chance(0.2) ? .null : positive(&generator)
  case "contextIndex", "chapter", "upTo", "openedChapter", "lastAdvancedChapter", "revision", "saveSeq": return positive(&generator)
  case "anchor": return anchor(&generator)
  case "unlock":
    return generator.chance(0.2)
      ? .null : object([("all", .array([object([("milestone", key(&generator))]), object([("chapter", positive(&generator))]), object([("ending", .bool(true))])]))])
  case "knowledgeContract":
    return generator.chance(0.2)
      ? .null : object([("pov", .array([key(&generator)])), ("learns", .array([object([("entityKey", key(&generator)), ("factKey", key(&generator))])]))])
  case "endingContract":
    return object([
      ("hookType", .string(generator.pick(from: HookType.allCases).rawValue)), ("emotionalBeat", text(&generator)), ("openQuestion", text(&generator)),
      ("handoffState", text(&generator)),
    ])
  case "scenes": return generator.chance(0.2) ? .null : scenes(&generator)
  case "frontmatter": return object([("status", text(&generator))])
  default: break
  }
  switch field.kind {
  case .string: return text(&generator)
  case .nullableString: return generator.chance(0.2) ? .null : text(&generator)
  case .boolean: return .bool(generator.chance(0.5))
  case .integer, .nullableInteger: return positive(&generator)
  case .strings: return texts(&generator, count: 0...3)
  case .nullableStrings: return generator.chance(0.2) ? .null : texts(&generator, count: 0...3)
  case .object, .nullableObject: return object([("k", text(&generator))])
  case .objects, .nullableObjects: return .array([object([("k", text(&generator))])])
  }
}

private func validOperation(_ generator: inout SeededGenerator) -> OrderedJSON {
  let op = generator.pick(from: OpType.allCases)
  let spec = op.spec
  var pairs: [(String, OrderedJSON)] = [("op", .string(op.rawValue))]
  for field in spec.required { pairs.append((field.name, fieldValue(op, field, &generator))) }
  for field in spec.optional where generator.chance(0.4) { pairs.append((field.name, fieldValue(op, field, &generator))) }
  if op == .draftUpdate, !pairs.contains(where: { ["title", "body", "summary"].contains($0.0) }) { pairs.append(("body", text(&generator))) }
  if op == .promiseSetPayoff, pairs.contains(where: { $0.0 == "someday" && $0.1 == .bool(true) }) {
    pairs.removeAll { ["payoffMilestoneKey", "payoffVolumeKey", "payoffWindow"].contains($0.0) }
  }
  return object(pairs)
}

private func validSet(_ generator: inout SeededGenerator) -> OrderedJSON {
  .array((0..<generator.int(in: 1...4)).map { _ in validOperation(&generator) })
}

private func arbitrary(_ generator: inout SeededGenerator, depth: Int) -> OrderedJSON {
  switch generator.int(in: 0...(depth > 0 ? 9 : 5)) {
  case 0: return .null
  case 1: return .bool(generator.chance(0.5))
  case 2: return .int(Int64(generator.int(in: -3...50)))
  case 3: return .double(Double(generator.int(in: -40...40)) / 4)
  case 4: return .string(generator.chance(0.5) ? generator.pick(from: arbitraryKeys) : generator.unicodeString(maxLength: 6))
  case 5: return .string(generator.pick(from: wordPool))
  case 6, 7: return .array((0..<generator.int(in: 0...3)).map { _ in arbitrary(&generator, depth: depth - 1) })
  default:
    let pairs = (0..<generator.int(in: 0...5)).map { _ in (generator.pick(from: arbitraryKeys), arbitrary(&generator, depth: depth - 1)) }
    return object(pairs)
  }
}

private func arbitrarySet(_ generator: inout SeededGenerator) -> OrderedJSON {
  guard generator.chance(0.7) else { return arbitrary(&generator, depth: 4) }
  return .array(
    (0..<generator.int(in: 0...3)).map { _ in
      guard generator.chance(0.7) else { return arbitrary(&generator, depth: 3) }
      var pairs = [("op", OrderedJSON.string(generator.pick(from: OpType.allCases).rawValue))]
      for _ in 0..<generator.int(in: 0...4) { pairs.append((generator.pick(from: arbitraryKeys), arbitrary(&generator, depth: 3))) }
      return object(pairs)
    })
}

private func withIgnoredMembers(_ value: OrderedJSON) -> OrderedJSON {
  switch value {
  case .array(let items): return .array(items.map(withIgnoredMembers))
  case .object(let record):
    var pairs = record.entries.map { (key: $0.key, value: $0.value) }
    for name in ignoredMembers where record[name] == nil { pairs.append((key: name, value: .int(7))) }
    return .object(OrderedJSONObject(pairs))
  default: return value
  }
}

private func topLevelWithIgnoredMembers(_ value: OrderedJSON) -> OrderedJSON {
  guard case .array(let items) = value else { return value }
  return .array(
    items.map { item in
      guard case .object(let record) = item else { return item }
      var pairs = record.entries.map { (key: $0.key, value: $0.value) }
      for name in ignoredMembers where record[name] == nil { pairs.append((key: name, value: .string("ignored"))) }
      return .object(OrderedJSONObject(pairs))
    })
}

private func looseningNestedObjects(_ value: OrderedJSON) -> OrderedJSON {
  guard case .array(let items) = value else { return value }
  return .array(
    items.map { item in
      guard case .object(let record) = item else { return item }
      let pairs = record.entries.map { entry -> (key: String, value: OrderedJSON) in
        guard ["endingContract", "anchor"].contains(entry.key), case .object(let nested) = entry.value else { return (key: entry.key, value: entry.value) }
        return (key: entry.key, value: .object(OrderedJSONObject(nested.entries.map { (key: $0.key, value: $0.value) } + [(key: "additionalMember", value: .bool(true))])))
      }
      return .object(OrderedJSONObject(pairs))
    })
}

struct ChangeSetPropertyTests {
  @Test func shouldNeverCrashOnArbitraryJSON() throws {
    try forAll(iterations: 600) { generator in
      let value = arbitrarySet(&generator)
      let scope = generator.chance(0.5) ? nil : Array(OpType.allCases.shuffled(using: &generator).prefix(generator.int(in: 0...10)))
      let options = ChangeSetValidationOptions(entityMaterialization: generator.chance(0.5))
      _ = validateChangeSet(value, allowedOps: scope, options: options)
      _ = validatePluginChangeSet(value)
      _ = try? parseChangeSet(value, allowedOps: scope, options: options)
      _ = try? parseOptionalChangeSet(value, allowedOps: scope, options: options)
    }
  }

  @Test func shouldRenderAnyListOfOperationsWithoutCrashing() throws {
    try forAll(iterations: 100) { generator in
      let ops = (0..<generator.int(in: 0...12)).map { _ in generator.pick(from: OpType.allCases) }
      _ = renderOpVocabulary(ops, OpVocabularyOptions(quotes: generator.chance(0.5)))
      _ = renderActionVocabulary(ops)
    }
  }

  @Test func shouldAcceptASetMadeOnlyOfGeneratedValidOperations() throws {
    try forAll(iterations: 500) { generator in
      let set = validSet(&generator)
      let result = validateChangeSet(set)
      guard result.errors.isEmpty else { throw CSPropertyError.rejected(set.jsonText, result.errors) }
      let ops = try parseChangeSet(set)
      guard case .array(let items) = set, ops.count == items.count else { throw CSPropertyError.rejected(set.jsonText, ["typed count differs"]) }
      _ = changeSetRefs(ops)
      _ = actionDecisionKeys(ops)
    }
  }

  @Test func shouldCoverEveryOperationTypeInGeneratedValidSets() throws {
    var generator = SeededGenerator(seed: 42)
    var seen = Set<OpType>()
    for _ in 0..<500 {
      guard case .array(let items) = validSet(&generator) else { continue }
      for item in items { if let name = item.objectValue?["op"]?.stringValue, let op = OpType(exactly: name) { seen.insert(op) } }
    }
    #expect(seen == Set(OpType.allCases))
  }

  @Test func shouldNotChangeAValidSetsVerdictWhenMembersTheReferenceIgnoresAreAdded() throws {
    try forAll(iterations: 300) { generator in
      let set = validSet(&generator)
      let loosened = topLevelWithIgnoredMembers(looseningNestedObjects(set))
      let errors = validateChangeSet(loosened).errors
      guard errors.isEmpty else { throw CSPropertyError.rejected(loosened.jsonText, errors) }
    }
  }

  @Test func shouldNotChangeTheErrorsOfArbitraryJSONWhenOpLevelMembersTheReferenceIgnoresAreAdded() throws {
    try forAll(iterations: 400) { generator in
      let value = arbitrarySet(&generator)
      let scope: [OpType]? = generator.chance(0.5) ? nil : OpType.allCases
      let before = validateChangeSet(value, allowedOps: scope).errors
      let after = validateChangeSet(topLevelWithIgnoredMembers(value), allowedOps: scope).errors
      guard csSameStrings(before, after) else { throw CSPropertyError.rejected(value.jsonText, before + ["!="] + after) }
    }
  }

  @Test func shouldIgnoreEveryMemberOfFrontmatter() throws {
    let plain = try csParse(#"[{"op": "bible_document.upsert", "section": "plot", "slug": "escalation-map", "frontmatter": {}}]"#)
    let loaded = withIgnoredMembers(try csParse(#"[{"op": "bible_document.upsert", "section": "plot", "slug": "escalation-map", "frontmatter": {"a": [1, {"b": null}]}}]"#))
    #expect(validateChangeSet(plain).errors.isEmpty)
    #expect(validateChangeSet(loaded).errors.isEmpty)
  }
}

private enum CSPropertyError: Error, CustomStringConvertible {
  case rejected(String, [String])

  var description: String {
    switch self {
    case .rejected(let json, let errors): "\(json) -> \(errors)"
    }
  }
}
