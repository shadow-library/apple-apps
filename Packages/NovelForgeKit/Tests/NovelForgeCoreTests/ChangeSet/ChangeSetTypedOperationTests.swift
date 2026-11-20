import Foundation
import ShadowText
import Testing

@testable import NovelForgeCore

private let safeIntegerLimit = 9_007_199_254_740_992.0

private func equalJSON(_ left: OrderedJSON, _ right: OrderedJSON) -> Bool {
  switch (left, right) {
  case (.array(let a), .array(let b)): return a.count == b.count && zip(a, b).allSatisfy { equalJSON($0, $1) }
  case (.object(let a), .object(let b)): return a.keys.count == b.keys.count && zip(a.entries, b.entries).allSatisfy { $0.key.jsEquals($1.key) && equalJSON($0.value, $1.value) }
  default:
    guard let a = left.numberValue, let b = right.numberValue else { return left == right }
    return a == b
  }
}

private func hasUnsafeNumber(_ value: OrderedJSON) -> Bool {
  switch value {
  case .int(let number): abs(Double(number)) >= safeIntegerLimit
  case .double(let number): abs(number) >= safeIntegerLimit
  case .array(let items): items.contains(where: hasUnsafeNumber)
  case .object(let object): object.entries.contains { hasUnsafeNumber($0.value) }
  default: false
  }
}

private func throughBriefScene(_ value: OrderedJSON) throws -> OrderedJSON {
  guard case .array(let scenes) = value else { return value }
  return .array(try scenes.map { scene in sceneJSON(try JSONDecoder().decode(BriefScene.self, from: Data(scene.jsonText.utf8))) })
}

private func restricted(_ value: OrderedJSON?, to actual: OrderedJSON?) -> OrderedJSON? {
  guard case .object(let expected)? = value, case .object(let kept)? = actual else { return value }
  return .object(OrderedJSONObject(expected.entries.filter { entry in kept.keys.contains { $0.jsEquals(entry.key) } }.map { (key: $0.key, value: $0.value) }))
}

private func differences(_ op: ChangeOp, from record: OrderedJSONObject) throws -> [String] {
  let encoded = op.fields
  let declared = declaredOpFields(op.type) + opMetadataFields
  var found: [String] = []
  for entry in record.entries where declared.contains(where: { $0.jsEquals(entry.key) }) {
    if hasUnsafeNumber(entry.value) { continue }
    var expected: OrderedJSON? = entry.value
    var actual = encoded[entry.key]
    if entry.key == "scenes" {
      expected = try throughBriefScene(entry.value)
      actual = try actual.map(throughBriefScene)
    }
    if entry.key == "endingContract" || entry.key == "anchor" { expected = restricted(expected, to: actual) }
    guard let expected, let actual, equalJSON(expected, actual) else {
      found.append("\(op.type.rawValue).\(entry.key)")
      continue
    }
  }
  for key in encoded.keys where !key.jsEquals("op") && record[key] == nil { found.append("\(op.type.rawValue) emitted \(key)") }
  return found
}

struct ChangeSetTypedOperationTests {
  @Test func shouldKeepEveryDeclaredFieldOfEveryValidFixtureOperationInItsTypedValue() throws {
    let fixture = try ChangeSetValidationFixture.load()
    var covered = Set<OpType>()
    var wrong: [String] = []
    for item in fixture.cases where item.errors?.isEmpty == true {
      if try item.isUnsafeIntegerDeviation(actual: fixture.run(item).errors) { continue }
      let value = try item.expectedValue
      guard case .array(let items) = value else { continue }
      let ops = try parseChangeSet(
        value, allowedOps: item.flag == 2 ? pluginAllowedOps : fixture.allowedOps(item.scope), options: ChangeSetValidationOptions(entityMaterialization: item.flag != 1))
      for (op, raw) in zip(ops, items) {
        covered.insert(op.type)
        if let record = raw.objectValue { wrong += try differences(op, from: record) }
      }
    }
    #expect(wrong.isEmpty, "\(wrong.count) differ, first: \(wrong.prefix(5))")
    #expect(covered == Set(OpType.allCases))
  }

  @Test func shouldDistinguishAnOmittedFieldFromANullOneInTheTypedValue() throws {
    let omitted = try csOp(#"{"op": "brief.update", "chapter": 1}"#)
    let cleared = try csOp(#"{"op": "brief.update", "chapter": 1, "direction": null, "contentMode": null, "scenes": null, "knowledgeContract": null}"#)
    guard case .briefUpdate(let omittedBrief) = omitted.operation, case .briefUpdate(let clearedBrief) = cleared.operation else {
      Issue.record("not briefs")
      return
    }
    #expect(omittedBrief.direction == .omitted && clearedBrief.direction == .null)
    #expect(omittedBrief.contentMode == .omitted && clearedBrief.contentMode == .null)
    #expect(omittedBrief.scenes == .omitted && clearedBrief.scenes == .null)
    #expect(omittedBrief.knowledgeContract == .omitted && clearedBrief.knowledgeContract == .null)
  }

  @Test func shouldRefuseToBuildAnOperationThisVersionDoesNotKnow() throws {
    #expect(throws: ChangeSetError.self) { try csOps(#"[{"op": "arc.upsert", "arcKey": "a1"}]"#) }
  }

  @Test func shouldCarryTheMetadataBesideTheOperation() throws {
    let op = try csOp(#"{"op": "brief.update", "chapter": 2, "rationale": "why", "quote": "q", "startedEmpty": true, "ideaId": "i1"}"#)
    #expect(
      op.metadata
        == OpMetadata(
          OpFields(
            record: OrderedJSONObject([
              (key: "rationale", value: .string("why")), (key: "quote", value: .string("q")), (key: "startedEmpty", value: .bool(true)), (key: "ideaId", value: .string("i1")),
            ]))))
    #expect(op.metadata.startedEmpty == true)
  }
}
