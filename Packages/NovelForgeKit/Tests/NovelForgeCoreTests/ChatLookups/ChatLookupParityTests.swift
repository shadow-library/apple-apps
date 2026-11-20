import Foundation
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

private func difference(_ actual: String, _ expected: String) -> String {
  let (left, right) = (actual.jsCodeUnits, expected.jsCodeUnits)
  let at = zip(left, right).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(left.count, right.count)
  let window = { (text: String) in text.jsSlice(max(at - 40, 0), at + 80) }
  return "first difference at \(at) of \(left.count)/\(right.count): actual \(window(actual).debugDescription) expected \(window(expected).debugDescription)"
}

private let descriptionDeviations: [String: String] = [
  "get_entity": "Retrieve an entity card by entity key: name, type, status and body (or notes).",
  "get_usage":
    "Retrieve the project's AI usage — cost, tokens and calls — for a period (today, week, month, all), with a per-role breakdown and whether the figures are estimated. Read-only; carries no prompt or answer content.",
]

private let argumentDeviations: [String: [String]] = ["get_usage": ["period"]]

@Suite("Chat lookups against the reference", TestTimeLimit.standard)
struct ChatLookupParityTests {
  private static let fixture = Result { try ChatLookupFixture.load() }

  private func fixture() throws -> ChatLookupFixture { try Self.fixture.get() }

  @Test func shouldDeclareExactlyTheLookupsTheReferenceOffersTheHubThatThisBuildAnswers() throws {
    let fixture = try fixture()
    #expect(ChatLookups.definitions.count == 12)
    for definition in ChatLookups.definitions {
      let reference = try #require(fixture.definitions.first { $0.name == definition.name.rawValue })
      #expect(definition.description.jsEquals(descriptionDeviations[reference.name] ?? reference.description), "\(reference.name) description")
      #expect(definition.arguments == (argumentDeviations[reference.name] ?? reference.arguments), "\(reference.name) arguments")
      #expect(definition.maxCallsPerRun == reference.maxCallsPerRun, "\(reference.name) calls")
      #expect(definition.tokensBudget == reference.tokensBudget, "\(reference.name) budget")
    }
    let referenceOrder = fixture.definitions.map(\.name).filter { name in ChatLookups.definitions.contains { $0.name.rawValue == name } }
    #expect(ChatLookups.definitions.map(\.name.rawValue) == referenceOrder)
  }

  @Test func shouldListTheLookupsInThePlaybookAsTheReferenceDoes() throws {
    let fixture = try fixture()
    let lines = chatScopeInstructions(ChatLookups.tools).jsSplit("\n").filter { $0.hasPrefix("- get_") || $0.hasPrefix("- search_") }
    let offered = Set(ChatLookups.definitions.map(\.name.rawValue))
    let reference = fixture.scopeLines.filter { line in offered.contains(where: { line.hasPrefix("- \($0) ") }) }
    let deviating = Set(descriptionDeviations.keys)
    #expect(lines.count == 12)
    #expect(lines.filter { line in !deviating.contains { line.hasPrefix("- \($0) ") } } == reference.filter { line in !deviating.contains { line.hasPrefix("- \($0) ") } })
    #expect(lines.contains("- get_usage (args: period) — \(descriptionDeviations["get_usage"] ?? "")"))
    #expect(lines.contains("- get_entity (args: entityKey) — \(descriptionDeviations["get_entity"] ?? "")"))
  }

  @Test func shouldTakeTheBibleSectionsFromTheReferenceEnum() throws {
    #expect(BiblePageSection.allCases.map(\.rawValue) == (try fixture()).bibleSections)
  }

  @Test func shouldAnswerEveryCaseAsTheReferenceDoes() async throws {
    let fixture = try fixture()
    var stores: [String: VaultStore] = [:]
    for (name, world) in fixture.worlds { stores[name] = try await ChatLookupWorlds.store(world) }
    for spec in fixture.cases {
      let service = ChatLookupService(store: try #require(stores[spec.world]), novel: readNovel)
      var counts = ChatLookupCounts()
      let calls = try spec.lookups.map { ChatLookupCall(tool: $0.tool, args: try parsedArguments($0.argsJSON)) }
      let round = try await service.execute(calls, counts: &counts)
      #expect(round.text.jsEquals(spec.expected.text), "\(spec.name): \(difference(round.text, spec.expected.text))")
      #expect(round.readsPlannerOnly == spec.expected.plannerRead, "\(spec.name): planner-only flag")
      #expect(round.outcomes.count == spec.expected.outcomes.count, "\(spec.name): outcomes")
      for (outcome, expected) in zip(round.outcomes, spec.expected.outcomes) {
        #expect(outcome.trace.tool == expected.tool, "\(spec.name)")
        #expect(outcome.trace.audit.rawValue == expected.status, "\(spec.name): \(expected.tool)")
        #expect(outcome.trace.status.rawValue == expected.traceStatus, "\(spec.name): \(expected.tool)")
        let traced = Dictionary(uniqueKeysWithValues: outcome.trace.args.entries.map { ($0.key, LookupTraceValue($0.value)) })
        #expect(traced == expected.trace, "\(spec.name): \(expected.tool) trace")
        #expect(outcome.trace.resultCharacters == outcome.result.jsLength)
      }
    }
  }

  @Test func shouldTraceArgumentsAsTheReferenceDoes() throws {
    let file = try ReferenceFixture.data("chat-lookups/chat-lookups.json")
    let root = try #require(try OrderedJSON(parsing: String(decoding: file, as: UTF8.self)).objectValue)
    let cases = try #require(root["trace"]?.arrayValue)
    #expect(cases.count > 100)
    for entry in cases {
      let fields = try #require(entry.objectValue)
      let tool = try #require(fields["tool"]?.stringValue)
      let arguments = try #require(try parsedArguments(fields["argsJSON"]?.stringValue))
      let expected = try #require(fields["expected"]?.objectValue)
      let actual = traceArgs(tool: tool, args: arguments)
      #expect(actual.entries.map(\.key) == expected.keys, "\(tool) \(fields["argsJSON"]?.stringValue ?? "")")
      for traced in actual.entries {
        switch (traced.value, expected[traced.key]) {
        case (.text(let text), .string(let reference)?): #expect(text.jsEquals(reference), "\(tool) \(traced.key)")
        case (.count(let count), let reference?): #expect(count == reference.numberValue, "\(tool) \(traced.key)")
        default: Issue.record("\(tool) \(traced.key) differs in kind")
        }
      }
    }
  }

  @Test func shouldFlagPlannerOnlyReadsAsTheReferenceDoes() throws {
    for entry in (try fixture()).plannerGuard {
      let arguments = try parsedArguments(entry.argsJSON).map(OrderedJSON.object)
      #expect(readsPlannerOnlyPage(tool: entry.tool, args: arguments) == entry.expected, "\(entry.tool) \(entry.argsJSON)")
    }
  }
}
