import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private struct RouterCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    ProviderCredential(origin: provider == .anthropic ? CompactionWorld.anthropic : CompactionWorld.openRouter, secret: "sk-test")
  }
}

private enum RouteWorld {
  static let novel = SchemaFixture.novel
  static let schema: JSONValue = ["type": "object", "properties": ["body": ["type": "string"]], "required": ["body"]]
  static let explicitBackground = "a child and intercourse in one line"
  static let suppliedOnly = "the schoolgirl looked sexy in the doorway"

  static func plan(_ mode: ContentMode? = .standard) -> ChapterPlanContent {
    ChapterPlanContent(body: "Mara crosses the river.", contentMode: mode.map { .known($0) })
  }

  static func source(_ role: ChapterRole = .draft, plan: ChapterPlanContent? = plan(), isolated: Bool = false, raised: Bool = false) -> ChapterCallSource {
    ChapterCallSource(novel: novel, chapter: 3, role: role, plan: plan, isolated: isolated, raised: raised)
  }

  static func router(_ provider: any ModelProvider, unrestrictedModel: String? = CompactionWorld.unrestrictedModel, guarded: Bool = true) async throws -> TaskRouter {
    let store = try ChatWorld.store().1
    guard let standard = ProviderBinding(origin: CompactionWorld.anthropic, provider: provider),
      let unrestricted = ProviderBinding(origin: CompactionWorld.openRouter, provider: provider)
    else { preconditionFailure("valid bindings") }
    try await store.write { transaction in
      for host in [standard.host, unrestricted.host] {
        try AIConsent.decide(.granted, provider: host, dataClass: CompactionWorld.consent.dataClass, summary: CompactionWorld.consent.disclosure, atMillis: 1, in: &transaction)
      }
    }
    let configuration = TaskRouterConfiguration(provider: .anthropic, assignments: OpenRouterAssignments(unrestricted: unrestrictedModel))
    return TaskRouter(
      configuration: configuration, anthropic: standard, openRouter: unrestricted, credentials: RouterCredentials(), store: store,
      requestGuard: { guarded ? ModelRequestGuard.hardLine(for: $0) : nil })
  }

  static func reply(_ body: String) -> [ScriptedModelProvider.Step] {
    ScriptedModelProvider.reply(String(decoding: CanonicalJSON.encode(["body": .string(body)]), as: UTF8.self))
  }

  static func input(guidance: String = "Keep it quiet.", stableContext: String = "Mara is a ferrywoman.") -> OrderedJSONObject {
    OrderedJSONObject([("stableContext", .string(stableContext)), ("chapterBrief", .string("Mara crosses the river.")), ("guidance", .string(guidance))])
  }

  static func run(_ route: ChapterCallRoute, router: TaskRouter, input: OrderedJSONObject = input(), sections: [ContextSection] = []) async throws(ChapterCallFailure)
    -> StructuredResult
  {
    try await route.run(
      router, pace: .steady, consent: CompactionWorld.consent, screening: input, sections: sections, lexicon: .standard,
      request: { $0.request(system: [ContextSegment(text: "Write the chapter.")], messages: [ModelMessage(role: .user, text: "Chapter 3.")]) }, name: "chapter-draft",
      schema: schema)
  }

  static func runText(_ route: ChapterCallRoute, router: TaskRouter, sections: [ContextSection] = []) async throws(ChapterCallFailure) -> ChapterTextResult {
    try await route.runText(
      router, pace: .steady, consent: CompactionWorld.consent, screening: input(), sections: sections, lexicon: .standard,
      request: { $0.request(system: [ContextSegment(text: "Judge the chapter.")], messages: [ModelMessage(role: .user, text: "Chapter 3.")]) })
  }
}

@Suite("Chapter call router", TestTimeLimit.standard)
struct ChapterCallRouterTests {
  @Test func shouldRouteAnUnrestrictedChapterStrictlyThroughTheHardLineGuard() async throws {
    let route = try ChapterCallRouter.route(RouteWorld.source(plan: RouteWorld.plan(.unrestricted)), unrestrictedAvailable: true)
    #expect(route.contentMode == .unrestricted && route.containment == .isolatedUnrestricted && route.task == .writing)
    let provider = ScriptedModelProvider(calls: [RouteWorld.reply("The river is cold.")])
    let result = try await RouteWorld.run(route, router: try await RouteWorld.router(provider))
    let request = try #require(provider.requests.first)
    #expect(request.model == CompactionWorld.unrestrictedModel)
    #expect(request.system.first?.text == hardLineSystemLine)
    #expect(result.callIDs.count == 1)
    let draft = route.contained(DraftContent(body: "The river is cold.", source: .known(.generated)))
    #expect(draft.generator == .known(.unrestricted) && draft.isolated)
  }

  @Test func shouldRefuseAChapterThatMustBeUnrestrictedWhenTheBuildCannotWriteIt() async throws {
    #expect(!UnrestrictedWriting.isAvailable)
    for source in [RouteWorld.source(plan: RouteWorld.plan(.unrestricted)), RouteWorld.source(.judge, isolated: true), RouteWorld.source(raised: true)] {
      do {
        _ = try ChapterCallRouter.route(source)
        Issue.record("expected a refusal of \(source)")
      } catch {
        #expect(error.code == "AI_024")
      }
    }
  }

  @Test func shouldRouteAnIsolatedChapterUnrestrictedWhateverItsPlanSays() throws {
    for role in ChapterRole.allCases {
      let route = try ChapterCallRouter.route(RouteWorld.source(role, isolated: true), unrestrictedAvailable: true)
      #expect(route.contentMode == .unrestricted && route.containment == .isolatedUnrestricted && route.task == role.modelTask, "\(role)")
    }
    let fresh = try ChapterCallRouter.route(RouteWorld.source(.judge, plan: RouteWorld.plan(.standard)), unrestrictedAvailable: true)
    #expect(fresh.contentMode == .standard && fresh.containment == nil && fresh.task == .review)
  }

  @Test func shouldRouteAChapterWithoutAPlanOrModeStandard() throws {
    for plan in [nil, RouteWorld.plan(nil)] {
      let route = try ChapterCallRouter.route(RouteWorld.source(plan: plan))
      #expect(route.contentMode == .standard && route.containment == nil)
    }
  }

  @Test func shouldRefuseAContentModeThisVersionCannotRead() {
    var plan = RouteWorld.plan()
    plan.contentMode = .unknown("explicit")
    do {
      _ = try ChapterCallRouter.route(RouteWorld.source(plan: plan), unrestrictedAvailable: true)
      Issue.record("expected a refusal")
    } catch {
      guard case .unknownContentMode("explicit") = error else {
        Issue.record("expected an unknown mode, got \(error)")
        return
      }
    }
  }

  @Test func shouldRouteARaisedCallUnrestrictedAndContainIt() throws {
    let route = try ChapterCallRouter.route(RouteWorld.source(raised: true), unrestrictedAvailable: true)
    #expect(route.contentMode == .unrestricted && route.containment == .isolatedUnrestricted)
  }

  @Test func shouldRefuseAHardLineInputBeforeSendingAndNameTheRecord() async throws {
    let route = try ChapterCallRouter.route(RouteWorld.source(plan: RouteWorld.plan(.unrestricted)), unrestrictedAvailable: true)
    let provider = ScriptedModelProvider(calls: [RouteWorld.reply("The river is cold.")])
    let router = try await RouteWorld.router(provider)
    let section = ContextSection(key: "characters", rendered: "Mara: \(RouteWorld.explicitBackground).", sourceRefs: ["entity:Mara"])
    do {
      _ = try await RouteWorld.run(route, router: router, sections: [section])
      Issue.record("expected a refusal")
    } catch {
      guard case .hardLine(let hit) = error.error else {
        Issue.record("expected a hard-line refusal, got \(error.error)")
        return
      }
      #expect(hit == HardLineHit(rule: .minorWithExplicitAct, source: "The Story Bible entry \"Mara\"", sourceRefs: ["entity:Mara"]))
      #expect(error.code == "AI_015" && error.callIDs.isEmpty)
    }
    #expect(provider.requests.isEmpty)
  }

  @Test func shouldHoldWhatTheAuthorSuppliedToTheFullListAndBackgroundToTheExplicitOne() async throws {
    let route = try ChapterCallRouter.route(RouteWorld.source(plan: RouteWorld.plan(.unrestricted)), unrestrictedAvailable: true)
    do {
      try route.screenInputs(RouteWorld.input(guidance: RouteWorld.suppliedOnly), lexicon: .standard)
      Issue.record("expected a refusal")
    } catch {
      guard case .hardLine(let hit) = error else {
        Issue.record("expected a hard-line refusal, got \(error)")
        return
      }
      #expect(hit == HardLineHit(rule: .minorWithSexualContent, source: "The guidance for this chapter", sourceRefs: []))
    }
    try route.screenInputs(RouteWorld.input(stableContext: RouteWorld.suppliedOnly), lexicon: .standard)
  }

  @Test func shouldRefuseAnOutputTheHardLineFindsBeforeItCanBeSaved() async throws {
    let route = try ChapterCallRouter.route(RouteWorld.source(plan: RouteWorld.plan(.unrestricted)), unrestrictedAvailable: true)
    let provider = ScriptedModelProvider(calls: [RouteWorld.reply("nothing but loli art")])
    let router = try await RouteWorld.router(provider)
    do throws(ChapterCallFailure) {
      _ = try await RouteWorld.run(route, router: router)
      Issue.record("expected a refusal")
    } catch {
      guard case .hardLine(let hit) = error.error else {
        Issue.record("expected a hard-line refusal, got \(error.error)")
        return
      }
      #expect(hit == HardLineHit(rule: .standaloneTerm, source: "The generated text", sourceRefs: []))
      #expect(error.callIDs.count == 1)
    }
    #expect(provider.requests.count == 1)
    #expect(throws: ChapterCallError.self) { try route.screenOutput(Data("not json: nothing but loli art".utf8), lexicon: .standard) }
  }

  @Test func shouldLeaveAStandardChapterCallUnscreened() async throws {
    let route = try ChapterCallRouter.route(RouteWorld.source())
    let provider = ScriptedModelProvider(calls: [RouteWorld.reply("nothing but loli art")])
    let section = ContextSection(key: "characters", rendered: RouteWorld.explicitBackground, sourceRefs: ["entity:Mara"])
    _ = try await RouteWorld.run(route, router: try await RouteWorld.router(provider), input: RouteWorld.input(guidance: RouteWorld.suppliedOnly), sections: [section])
    let request = try #require(provider.requests.first)
    #expect(request.model != CompactionWorld.unrestrictedModel && request.system.first?.text != hardLineSystemLine)
  }

  @Test func shouldRefuseAnUnrestrictedRouteTheRouterCannotHold() async throws {
    let route = try ChapterCallRouter.route(RouteWorld.source(plan: RouteWorld.plan(.unrestricted)), unrestrictedAvailable: true)
    let provider = ScriptedModelProvider(calls: [RouteWorld.reply("The river is cold.")])
    let (unguarded, unassigned) = (try await RouteWorld.router(provider, guarded: false), try await RouteWorld.router(provider, unrestrictedModel: nil))
    do throws(ChapterCallFailure) {
      _ = try await RouteWorld.run(route, router: unguarded)
      Issue.record("expected a refusal")
    } catch {
      guard case .routeMismatch(.unrestricted) = error.error else {
        Issue.record("expected an unguarded route, got \(error.error)")
        return
      }
      #expect(error.callIDs.isEmpty)
    }
    do throws(ChapterCallFailure) {
      _ = try await RouteWorld.run(route, router: unassigned)
      Issue.record("expected a refusal")
    } catch {
      guard case .routing(.unrestrictedModelMissing) = error.error else {
        Issue.record("expected a missing unrestricted model, got \(error.error)")
        return
      }
    }
    #expect(provider.requests.isEmpty)
  }

  @Test func shouldRefuseARepairReAskTheGuardFindsAndKeepTheFirstCallsID() async throws {
    let route = try ChapterCallRouter.route(RouteWorld.source(plan: RouteWorld.plan(.unrestricted)), unrestrictedAvailable: true)
    let provider = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("not json: \(RouteWorld.explicitBackground)"), RouteWorld.reply("The river is cold.")])
    let router = try await RouteWorld.router(provider)
    do throws(ChapterCallFailure) {
      _ = try await RouteWorld.run(route, router: router)
      Issue.record("expected a refusal")
    } catch {
      guard case .hardLine(let hit) = error.error else {
        Issue.record("expected a hard-line refusal, got \(error.error)")
        return
      }
      #expect(hit == HardLineHit(rule: .minorWithExplicitAct, source: "The request", sourceRefs: []))
      #expect(error.callIDs.count == 1)
    }
    #expect(provider.requests.count == 1)
  }

  @Test func shouldContainRevisedProseAsTheReferenceDoes() throws {
    let standard = try ChapterCallRouter.route(RouteWorld.source(.revise))
    let unrestricted = try ChapterCallRouter.route(RouteWorld.source(.revise, plan: RouteWorld.plan(.unrestricted)), unrestrictedAvailable: true)
    let revised = DraftContent(body: "Revised.", source: .known(.revised))
    let handWritten = DraftContent(body: "Mine.", source: .known(.handEdited), generator: .known(.human))
    let isolated = DraftContent(body: "Walled.", source: .known(.generated), generator: .known(.human), isolated: true)

    let kept = standard.contained(revised, revising: handWritten)
    #expect(kept.generator == .known(.human) && !kept.isolated)
    let fresh = standard.contained(DraftContent(body: "New.", source: .known(.generated), generator: .known(.human), isolated: true))
    #expect(fresh.generator == .known(.standard) && !fresh.isolated)
    let raised = unrestricted.contained(revised, revising: handWritten)
    #expect(raised.generator == .known(.unrestricted) && raised.isolated)
    let sticky = unrestricted.contained(revised, revising: isolated)
    #expect(sticky.generator == .known(.human) && sticky.isolated)
  }

  @Test func shouldScreenInputsAndOutputWithTheNovelsMinorNames() throws {
    let route = try ChapterCallRouter.route(RouteWorld.source(plan: RouteWorld.plan(.unrestricted)), unrestrictedAvailable: true)
    let pip = EntityRecord(novel: RouteWorld.novel, entity: "pip", type: .known(.character), name: "Pip", age: 15)
    let lexicon = HardLineLexicon.standard(withMinorsIn: [pip])
    let section = ContextSection(key: "characters", rendered: "Pip and the orgasm.", sourceRefs: ["entity:pip"])
    let output = Data(#"{"body":"Pip and the orgasm."}"#.utf8)
    #expect(throws: ChapterCallError.self) { try route.screenInputs(RouteWorld.input(), sections: [section], lexicon: lexicon) }
    #expect(throws: ChapterCallError.self) { try route.screenOutput(output, lexicon: lexicon) }
    try route.screenInputs(RouteWorld.input(), sections: [section], lexicon: .standard)
    try route.screenOutput(output, lexicon: .standard)
  }

  @Test func shouldSendATextCallAsWrittenAndReturnItsReplyAndCallID() async throws {
    let route = try ChapterCallRouter.route(RouteWorld.source(.judge, plan: RouteWorld.plan(.unrestricted)), unrestrictedAvailable: true)
    let provider = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("not json: the river is cold")])
    let result = try await RouteWorld.runText(route, router: try await RouteWorld.router(provider))
    #expect(result.text == "not json: the river is cold" && result.callIDs.count == 1)
    let request = try #require(provider.requests.first)
    #expect(request.messages.map(\.text) == ["Chapter 3."] && request.format == .text && request.system.first?.text == hardLineSystemLine)
  }

  @Test func shouldRefuseAHardLineInputOfATextCallBeforeSending() async throws {
    let route = try ChapterCallRouter.route(RouteWorld.source(.judge, plan: RouteWorld.plan(.unrestricted)), unrestrictedAvailable: true)
    let provider = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("The river is cold.")])
    let section = ContextSection(key: "characters", rendered: "Mara: \(RouteWorld.explicitBackground).", sourceRefs: ["entity:Mara"])
    let router = try await RouteWorld.router(provider)
    do throws(ChapterCallFailure) {
      _ = try await RouteWorld.runText(route, router: router, sections: [section])
      Issue.record("expected a refusal")
    } catch {
      guard case .hardLine(let hit) = error.error else {
        Issue.record("expected a hard-line refusal, got \(error.error)")
        return
      }
      #expect(hit.sourceRefs == ["entity:Mara"] && error.callIDs.isEmpty)
    }
    #expect(provider.requests.isEmpty)
  }

  @Test func shouldRefuseATextReplyTheHardLineFindsAndKeepItsCallID() async throws {
    let route = try ChapterCallRouter.route(RouteWorld.source(.judge, plan: RouteWorld.plan(.unrestricted)), unrestrictedAvailable: true)
    let provider = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("nothing but loli art")])
    let router = try await RouteWorld.router(provider)
    do throws(ChapterCallFailure) {
      _ = try await RouteWorld.runText(route, router: router)
      Issue.record("expected a refusal")
    } catch {
      guard case .hardLine(let hit) = error.error else {
        Issue.record("expected a hard-line refusal, got \(error.error)")
        return
      }
      #expect(hit == HardLineHit(rule: .standaloneTerm, source: "The generated text", sourceRefs: []) && error.callIDs.count == 1)
    }
  }
}
