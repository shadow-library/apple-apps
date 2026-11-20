import ShadowText
import Testing

@testable import NovelForgeCore

struct ChangeSetValidationParityTests {
  @Test func shouldCarryEnoughCasesOfEveryKind() throws {
    let fixture = try ChangeSetValidationFixture.load()
    #expect(fixture.cases.count >= 1_500)
    #expect(fixture.cases.contains { $0.errors?.isEmpty == true })
    #expect(fixture.cases.contains { $0.errors?.isEmpty == false })
    #expect(fixture.cases.contains { $0.repaired != nil })
    let messages = fixture.cases.flatMap { $0.errors ?? [] }.map { message in message.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "" }
    #expect(Set(messages).count >= 60)
  }

  @Test func shouldReturnTheReferenceErrorsInTheReferenceOrder() throws {
    let fixture = try ChangeSetValidationFixture.load()
    var mismatches: [String] = []
    var deviations = 0
    for item in fixture.cases {
      guard let expected = item.errors else { continue }
      let actual = try fixture.run(item).errors
      if csSameStrings(actual, expected) { continue }
      if try item.isUnsafeIntegerDeviation(actual: actual) {
        deviations += 1
        continue
      }
      mismatches.append("\(item.text) scope \(item.scope) flag \(item.flag): \(actual) != \(expected)")
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) differ, first: \(mismatches.prefix(3))")
    #expect(deviations >= 10, "the fixture should hold cases the reference accepts with an unsafe integer")
  }

  @Test func shouldReturnTheRepairedValueTheReferenceLeavesBehind() throws {
    let fixture = try ChangeSetValidationFixture.load()
    var mismatches: [String] = []
    for item in fixture.cases where item.errors != nil {
      let actual = try fixture.run(item).value
      if try actual != item.expectedValue { mismatches.append(item.text) }
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) differ, first: \(mismatches.prefix(3))")
  }

  @Test func shouldReportAnOperationNamedLikeAnObjectPrototypeMemberAsUnknownWhereTheReferenceThrows() throws {
    let fixture = try ChangeSetValidationFixture.load()
    let throwing = fixture.cases.filter { $0.errors == nil }
    #expect(throwing.count == 12)
    for item in throwing {
      let errors = try fixture.run(item).errors
      #expect(errors.count == 1 && errors[0].hasPrefix("changeSet[0]: unknown op '"))
    }
  }

  @Test func shouldBuildTypedOperationsExactlyForTheSetsTheReferenceAccepts() throws {
    let fixture = try ChangeSetValidationFixture.load()
    var wrong: [String] = []
    for item in fixture.cases {
      guard let expected = item.errors else { continue }
      let allowed = item.flag == 2 ? pluginAllowedOps : fixture.allowedOps(item.scope)
      let options = ChangeSetValidationOptions(entityMaterialization: item.flag != 1)
      let built = try? parseChangeSet(item.input, allowedOps: allowed, options: options)
      let pluginOnly = item.flag == 2 && !expected.isEmpty && expected.allSatisfy { $0.contains("is not allowed for this scope") && $0.contains("field '") }
      if pluginOnly { continue }
      if built == nil, try item.isUnsafeIntegerDeviation(actual: fixture.run(item).errors) { continue }
      if (built != nil) != expected.isEmpty { wrong.append(item.text) }
      if let built, case .array(let items) = try item.input, built.count != items.count { wrong.append(item.text) }
    }
    #expect(wrong.isEmpty, "\(wrong.count) differ, first: \(wrong.prefix(3))")
  }

  @Test func shouldThrowTheReferenceCodeAndMessageWhenParsingARejectedSet() throws {
    let spec = try ChangeSetSpecFixture.load()
    let rejected = try csParse(#"[{"op":"nope"}]"#)
    let empty = try csParse("[]")
    #expect(throws: ChangeSetError.self) { try parseChangeSet(empty) }
    do {
      _ = try parseChangeSet(rejected)
      Issue.record("expected a throw")
    } catch {
      #expect(error.code == spec.rejection.code)
      #expect(error.errorDescription == spec.rejection.message)
      #expect(error == .notAllowedForScope(problems: ["changeSet[0]: unknown op 'nope'"]))
    }
  }

  @Test func shouldParseAnOptionalChangeSetAsTheReferenceDoes() throws {
    let fixture = try ChangeSetValidationFixture.load()
    let cases = try ReferenceFixture.decode(ChangeSetOptionalFixture.self, from: "change-set/optional.json").cases
    #expect(cases.count >= 20)
    for item in cases {
      let raw = try item.text.map(csParse)
      let result: String
      do {
        result = try parseOptionalChangeSet(raw, allowedOps: fixture.allowedOps(item.scope)).isEmpty ? "empty" : "ok"
      } catch {
        result = "rejected"
      }
      #expect(result == (item.result == "throws" ? "rejected" : item.result), "\(item.text ?? "undefined") scope \(item.scope)")
    }
  }
}
