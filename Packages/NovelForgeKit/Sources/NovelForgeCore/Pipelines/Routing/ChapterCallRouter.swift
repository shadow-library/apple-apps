import Foundation
import OSLog
import ShadowAI
import ShadowCore

/// One model call about a chapter. The plan head carries the chapter's mode, copied from the novel's when the plan was made, so changing the novel's mode never
/// re-routes a chapter (chapter-route.ts:34). `isolated` is whether the prose the call reads is walled off: a draft's or canon's own flag, false for a call that
/// drafts afresh. `raised` is the reference's plugin raise of the writer class (chapter-generation.graph.ts:122); no native policy raises yet.
struct ChapterCallSource: Sendable, Equatable {
  let novel: UUID
  let chapter: Int
  let role: ChapterRole
  let plan: ChapterPlanContent?
  let isolated: Bool
  let raised: Bool

  init(novel: UUID, chapter: Int, role: ChapterRole, plan: ChapterPlanContent?, isolated: Bool, raised: Bool = false) {
    self.novel = novel
    self.chapter = chapter
    self.role = role
    self.plan = plan
    self.isolated = isolated
    self.raised = raised
  }
}

struct ChapterCallRoute: Sendable, Equatable {
  let novel: UUID
  let chapter: Int
  let role: ChapterRole
  let contentMode: ModelContentMode
  /// Set when what the call writes must be stored as isolated unrestricted prose (chapter-route.ts:45-47).
  let containment: ChapterContainment?

  fileprivate init(novel: UUID, chapter: Int, role: ChapterRole, contentMode: ModelContentMode, containment: ChapterContainment?) {
    self.novel = novel
    self.chapter = chapter
    self.role = role
    self.contentMode = contentMode
    self.containment = containment
  }

  var task: ModelTask { role.modelTask }
}

enum ChapterCallRouter {
  static let logger = Logger(category: "chapter.route")

  /// Strict: a chapter that must be unrestricted is refused (`AI_024`) where this build cannot write it, never sent standard. A mode the plan names that this
  /// version cannot read is refused rather than guessed. `TaskRouter` has no build-flag check, so this is the gate, as `ChatTurnPreparation` is for chat.
  // apps/novel-forge-server/src/modules/ai/chapter-route.ts:35-38,45-47,70-75; graphs/chapter-generation.graph.ts:123-126
  static func route(_ source: ChapterCallSource, unrestrictedAvailable: Bool = UnrestrictedWriting.isAvailable) throws(ChapterCallError) -> ChapterCallRoute {
    let planMode: ModelContentMode?
    switch source.plan?.contentMode {
    case nil: planMode = nil
    case .known(let mode)?: planMode = mode.modelContentMode
    case .unknown(let raw)?: throw .unknownContentMode(raw)
    }
    let chapterMode = chapterContentMode(ChapterModeSource(planMode: planMode, isolated: source.isolated))
    let mode = source.raised ? .unrestricted : chapterMode
    guard mode == .standard || unrestrictedAvailable else {
      logger.notice("Refused an unrestricted chapter call role=\(source.role.rawValue, privacy: .public) chapter=\(source.chapter, privacy: .public) code=AI_024")
      throw .unrestrictedUnavailable
    }
    return ChapterCallRoute(
      novel: source.novel, chapter: source.chapter, role: source.role, contentMode: mode, containment: chapterContainment(mode: mode, raised: source.raised))
  }
}

extension ChapterCallRoute {
  private func taskCall(pace: Pace, thinksDeeper: Bool = false, consent: AIConsentRequirement) -> TaskCall {
    TaskCall(task: task, pace: pace, thinksDeeper: thinksDeeper, contentMode: contentMode, consent: consent)
  }

  /// The routed call holds the chapter's mode, and an unrestricted one carries the route-owned hard-line guard (E05) that screens every request it sends.
  private func prepare(_ router: TaskRouter, pace: Pace, thinksDeeper: Bool = false, consent: AIConsentRequirement) async throws(ChapterCallError) -> RoutedCall {
    let call: RoutedCall
    do {
      call = try await router.prepare(taskCall(pace: pace, thinksDeeper: thinksDeeper, consent: consent))
    } catch {
      throw .routing(error)
    }
    guard call.route.contentMode == contentMode, contentMode == .standard || call.requestGuard != nil else { throw .routeMismatch(call.route.contentMode) }
    return call
  }

  /// An unrestricted call's writer-pack sections, each named by its records, then its prompt inputs, each at its scope; a standard model holds the line itself,
  /// so a standard call is not screened.
  // apps/novel-forge-server/src/modules/ai/context/pack-finalize.ts:36-39; model-router.service.ts:464,721-726
  func screenInputs(_ input: OrderedJSONObject, sections: [ContextSection] = []) throws(ChapterCallError) {
    guard contentMode == .unrestricted, let hit = screenTexts(sectionScreens(sections) + inputScreens(input)) else { return }
    throw refused(hit)
  }

  /// What an unrestricted model wrote, held to its role's scope before anything keeps it; text that is not JSON is screened whole.
  // apps/novel-forge-server/src/modules/ai/model-router.service.ts:705-708,761-781
  func screenOutput(_ json: Data) throws(ChapterCallError) {
    guard contentMode == .unrestricted else { return }
    let text = String(decoding: json, as: UTF8.self)
    let output = (try? OrderedJSON(parsing: text)) ?? .string(text)
    guard let hit = screenTexts(outputScreens(output, role: role.aiRole)) else { return }
    throw refused(hit)
  }

  /// The only way a chapter call is sent: screens the inputs, routes, sends and screens the result, so what returns may be saved. Callers save or checkpoint
  /// only the returned result and never render the deltas of an unrestricted call, which the result screen has not yet passed.
  func run(
    _ router: TaskRouter, pace: Pace, thinksDeeper: Bool = false, consent: AIConsentRequirement, screening input: OrderedJSONObject, sections: [ContextSection] = [],
    request: (RoutedCall) -> ModelRequest, name: String, schema: JSONValue, review: StructuredReview = .none, observer: (StructuredStreamEvent) -> Void = { _ in }
  ) async throws(ChapterCallFailure) -> StructuredResult {
    let call: RoutedCall
    do throws(ChapterCallError) {
      try screenInputs(input, sections: sections)
      call = try await prepare(router, pace: pace, thinksDeeper: thinksDeeper, consent: consent)
    } catch {
      throw ChapterCallFailure(error: error, callIDs: [])
    }
    let result: StructuredResult
    do throws(StructuredStreamFailure) {
      result = try await call.streamStructured(request(call), name: name, schema: schema, review: review, observer: observer)
    } catch {
      throw ChapterCallFailure(error: error.error.hardLineHit.map(refused) ?? .model(error.error), callIDs: error.callIDs)
    }
    do throws(ChapterCallError) {
      try screenOutput(result.json)
    } catch {
      throw ChapterCallFailure(error: error, callIDs: result.callIDs)
    }
    return result
  }

  /// Prose this call drafts takes the route's generator and isolation. Prose revised from `previous` stays isolated if that was, and a standard revision keeps
  /// the generator it had.
  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:132,158-159; generation/generation.service.ts:401
  func contained(_ content: DraftContent, revising previous: DraftContent? = nil) -> DraftContent {
    var contained = content
    if let previous, previous.isolated || containment == nil {
      contained.generator = previous.generator
      contained.isolated = previous.isolated
      return contained
    }
    contained.generator = .known(containment == nil ? .standard : .unrestricted)
    contained.isolated = containment != nil
    return contained
  }

  private func refused(_ hit: HardLineHit) -> ChapterCallError {
    ChapterCallRouter.logger.notice(
      "The hard line refused a chapter call role=\(role.rawValue, privacy: .public) chapter=\(chapter, privacy: .public) rule=\(hit.rule.rawValue, privacy: .public) source=\(hit.source, privacy: .private)"
    )
    return .hardLine(hit)
  }
}
