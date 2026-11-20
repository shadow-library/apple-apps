import Foundation
import NovelForgeCore
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText

@testable import NovelForgeEval

enum EvalScript {
  static let origin = URL(string: "https://api.example.com") ?? URL(fileURLWithPath: "/")

  static let body =
    "Mara climbed the lighthouse stairs at dusk with the lamp in her hand. She found the logbook open on the desk and its last page torn away. Outside the gulls wheeled over the black water and the tide came in fast."

  static var plan: JSONValue {
    [
      "title": "The Torn Page", "objective": "Mara finds the logbook torn.",
      "scenes": [
        [
          "summary": "Mara climbs the lighthouse.", "pov": "mara", "goal": "Find the logbook", "obstacle": "The stairs are dark", "turn": "The last page is gone",
          "beats": ["She climbs at dusk"], "estimatedWords": 1100,
        ]
      ],
      "requiredContext": ["entity:mara"],
      "endingContract": ["hookType": "turn", "emotionalBeat": "unease", "openQuestion": "Who tore the page?", "handoffState": "Mara at the desk"],
      "chapterPurpose": "Open the logbook's mystery.", "readerValue": ["new_information"],
    ]
  }

  static func reply(_ json: JSONValue) -> [ScriptedModelProvider.Step] {
    ScriptedModelProvider.reply(String(decoding: CanonicalJSON.encode(json), as: UTF8.self))
  }

  static var calls: [[ScriptedModelProvider.Step]] {
    let compliant: JSONValue = ["compliant": true, "issues": []]
    return [
      reply(plan),
      reply([
        "title": "The Torn Page", "body": .string(body), "summary": "Mara finds the logbook torn.",
        "state": ["lastBeat": "The tide comes in.", "openConflict": "Who tore the page?"],
      ]),
      reply(["verdict": "consistent", "findings": [], "readabilityCompliance": compliant, "briefCompliance": compliant]),
      reply(["verdict": "consistent", "findings": [], "knowledgeCompliance": compliant, "readabilityCompliance": compliant]),
      reply([
        "appeared": ["mara"], "newEntities": [], "threads": [], "mysteries": [], "timeline": [], "relationships": [], "power": [],
        "characterStates": [["entityKey": "mara", "location": "the lighthouse", "evidence": "Mara climbed the lighthouse stairs at dusk"]], "knowledgeChanges": [],
        "chapterSummary": "Mara finds the logbook torn.", "milestones": [],
      ]),
      reply(["updates": []]),
    ]
  }

  static func backend(_ provider: ScriptedModelProvider) throws -> EvalBackend {
    try EvalBackend(provider: provider, origin: origin, secret: "sk-test")
  }

  static func run(calls: [[ScriptedModelProvider.Step]] = EvalScript.calls, chapters: Int = 1) async throws -> (report: EvalReport, provider: ScriptedModelProvider) {
    let store = try NovelForgeStore.openInMemory()
    try await EvalFixture.seed(in: store)
    let provider = ScriptedModelProvider(calls: calls)
    let report = try await EvalRunner(store: store, backend: try backend(provider), consent: .record).run(novel: EvalFixture.novel, chapters: chapters)
    return (report, provider)
  }
}
