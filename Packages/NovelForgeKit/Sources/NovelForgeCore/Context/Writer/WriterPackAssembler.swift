import ShadowCore
import ShadowStore

enum WriterPackError: ShadowError {
  /// CTX_002: the writer's required material is over a limit or the budget.
  case contextTooLarge(detail: String, section: String?, overBy: Int)
  case disclosure(DisclosureError)
  case hardLine(HardLineError)
  /// A part the disclosure policy is built from could not be read, so nothing could be scrubbed against it.
  case unreadable([WriterPackPart])
  case store(StoreError)

  var code: String {
    switch self {
    case .contextTooLarge: "CTX_002"
    case .disclosure(let error): error.code
    case .hardLine(let error): error.code
    case .unreadable: "writer-pack.unreadable"
    case .store(let error): error.code
    }
  }

  var errorDescription: String? {
    switch self {
    // apps/novel-forge-server/src/classes/app-error-code.ts:200
    case .contextTooLarge(let detail, _, _): "The writer's required material does not fit — \(detail)."
    case .disclosure(let error): error.errorDescription
    case .hardLine(let error): error.errorDescription
    case .unreadable(let parts): "The chapter's context could not be read on this device: \(parts.map(\.rawValue).joined(separator: ", "))."
    case .store(let error): error.errorDescription
    }
  }
}

struct WriterPackOptions: Equatable, Sendable {
  // context-assembler.service.ts:126
  static let defaultBudget = 24_000

  var budgetTokens = defaultBudget
  /// The permissive (unrestricted) writing route: it reads isolated chapters as written.
  var permissive = false
  /// The novel's minor characters' names (`minorNames(in:)`), which the permissive pack's hard-line screen treats as minor terms.
  var minorNames: [String] = []
  /// Only the calls that write or revise the chapter fail on oversized required material; readers of the pack take it with its omissions.
  var enforceReservations = false
}

/// The writer's context for one chapter. `renderedStable` leads the request as its cached prefix; `brief` is the plan the writer reads beside the pack, scrubbed
/// by the same `disclosure`, which the caller keeps for whatever else it shows the writer.
// apps/novel-forge-server/src/modules/ai/context/sections.ts:29 (AssembledPack)
struct WriterPack: Equatable, Sendable {
  var chapter: Int
  /// What the pack could fill: the budget less the plan's tokens.
  var budgetTokens: Int
  var usedTokens: Int
  var sections: [ChatPackSection]
  var unresolvedRefs: [String]
  var withheldRefs: [String]
  var omitted: [ChatPackOmission]
  var renderedStable: String
  var renderedVolatile: String
  var rendered: String
  var brief: WriterBrief
  var reservations: [WriterReservation]
}

extension WriterPack {
  /// The generation prompt's input, the stable context leading as its cached prefix; `guidance` is the run's feedback, scrubbed by the pack's policy.
  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:477-516
  func generationInput(guidance: String) -> ChapterGenerationInput {
    ChapterGenerationInput(
      stableContext: renderedStable, volatileContext: renderedVolatile, chapterBrief: brief.chapterBrief, endingContract: brief.endingContract, guidance: guidance)
  }
}

private let largestNamed = 2
// context-assembler.service.ts:348
private let carriedKeys: Set<JSString> = ["hidden_constraints", "open_canon", "volume_objective", "completed_volumes"]

private func tokenCount(_ value: Int) -> String { Double(value).enUSGrouped }

/// Fails when a required section is over its limit or the required sections together are over the writer's budget.
// apps/novel-forge-server/src/modules/ai/context/writer-context.ts:57
func assertWriterContextFits(_ reservations: [WriterReservation], budgetTokens: Int) throws(WriterPackError) {
  if let over = reservations.first(where: { $0.tokens > $0.cap }) {
    let overBy = over.tokens - over.cap
    let detail = "\(over.name) is \(tokenCount(over.tokens)) tokens, \(tokenCount(overBy)) over its \(tokenCount(over.cap))-token limit; shorten it and try again"
    throw .contextTooLarge(detail: detail, section: over.name, overBy: overBy)
  }
  let total = reservations.reduce(0) { $0 + $1.tokens }
  if total <= budgetTokens { return }
  let overBy = total - budgetTokens
  let planned = reservations.filter(\.fromPlan).reduce(0) { $0 + $1.tokens }
  if planned * 2 > total {
    let detail =
      "the chapter plan and the characters it names take \(tokenCount(planned)) of the \(tokenCount(total)) tokens the required material needs, "
      + "\(tokenCount(overBy)) over the writer's \(tokenCount(budgetTokens))-token budget — shorten the plan or name fewer characters in it"
    throw .contextTooLarge(detail: detail, section: "the chapter plan", overBy: overBy)
  }
  var running = 0
  let crossing = reservations.first { reservation in
    running += reservation.tokens
    return running > budgetTokens
  }
  let largest = reservations.jsStableSorted { $0.tokens > $1.tokens }.prefix(largestNamed).map { "\($0.name) \(tokenCount($0.tokens))" }
  let detail =
    "with \(crossing?.name ?? "the last section") the required material reaches \(tokenCount(total)) tokens, "
    + "\(tokenCount(overBy)) over the writer's \(tokenCount(budgetTokens))-token budget (largest: \(largest.joined(separator: ", "))); shorten the largest and try again"
  throw .contextTooLarge(detail: detail, section: crossing?.name, overBy: overBy)
}

// apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:112 (chapterWriterRefs)
func chapterWriterRefs(_ plan: WriterPackPlan?) -> [String] {
  let contextRefs = plan?.contextRefs ?? []
  return contextRefs + castRefs(plan).filter { ref in !contextRefs.contains { $0.jsEquals(ref) } }
}

private func castRefs(_ plan: WriterPackPlan?) -> [String] {
  let pov = plan?.pov
  return (plan?.knowledge?.pov ?? []).jsUnique().filter { key in !(pov.map(key.jsEquals) ?? false) }.map { "entity:\($0)" }
}

enum WriterPackAssembler {
  /// The writer pack of `chapter`. Required sections are reserved, cut to their caps and always kept; the optional ones claim what the budget leaves by priority.
  /// Stable sections lead the rendered pack so its prefix stays byte-identical across calls while the canon is unchanged. An isolated chapter's prose, summary
  /// and state reach only the permissive route; isolation bridges are not built, so a standard route reads it as walled off. A permissive pack is screened for the
  /// hard line (native-only, see `finalize`).
  // apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:193 (forChapter), with no plugin sections
  static func assemble(
    _ world: WriterPackWorld, chapter: Int, options: WriterPackOptions = WriterPackOptions(), disclosure given: WriterDisclosurePolicy? = nil
  ) throws(WriterPackError) -> (pack: WriterPack, disclosure: WriterDisclosurePolicy) {
    let composed: Composed
    do {
      composed = try compose(world, chapter: chapter, rawIsolated: options.permissive, given: given)
    } catch {
      throw .disclosure(error)
    }
    if options.enforceReservations { try assertWriterContextFits(composed.rendered.reservations, budgetTokens: options.budgetTokens) }
    let finished = try finalize(
      composed.rendered.sections, budgetTokens: max(0, options.budgetTokens - composed.planTokens), screen: options.permissive ? options.minorNames : nil,
      omitted: composed.rendered.omitted)
    let pack = WriterPack(
      chapter: chapter, budgetTokens: finished.budgetTokens, usedTokens: finished.usedTokens, sections: finished.sections, unresolvedRefs: composed.unresolved,
      withheldRefs: composed.withheld, omitted: finished.omitted, renderedStable: finished.renderedStable, renderedVolatile: finished.renderedVolatile,
      rendered: finished.rendered, brief: composed.brief, reservations: composed.rendered.reservations)
    return (pack, composed.disclosure)
  }

  /// A loaded vault's pack, with the policy it was scrubbed by and the sources that policy was built from, so a caller that keeps the sources rebuilds it.
  static func assemble(
    _ load: WriterPackLoad, chapter: Int, options: WriterPackOptions
  ) throws(WriterPackError) -> (pack: WriterPack, disclosure: WriterDisclosurePolicy, sources: WriterDisclosureSources) {
    var options = options
    options.minorNames = (options.minorNames + load.minorNames).jsUnique()
    let sources = writerDisclosureSources(in: load.world.disclosureWorld, chapter: chapter)
    let policy: WriterDisclosurePolicy
    do throws(DisclosureError) {
      policy = try writerDisclosurePolicy(sources)
    } catch {
      throw .disclosure(error)
    }
    let built = try assemble(load.world, chapter: chapter, options: options, disclosure: policy)
    return (built.pack, built.disclosure, sources)
  }

  private struct Composed {
    var rendered: WriterRendered
    var planTokens: Int
    var brief: WriterBrief
    var unresolved: [String]
    var withheld: [String]
    var disclosure: WriterDisclosurePolicy
  }

  // context-assembler.service.ts:194-405
  private static func compose(_ world: WriterPackWorld, chapter: Int, rawIsolated: Bool, given: WriterDisclosurePolicy?) throws(DisclosureError) -> Composed {
    let plan = world.plan(for: chapter)
    let disclosureWorld = world.disclosureWorld
    var disclosure: WriterDisclosurePolicy
    if let given { disclosure = given } else { disclosure = try writerDisclosurePolicy(in: disclosureWorld, chapter: chapter) }
    let currentKey = plan?.volume ?? nearestVolumeKey(world.plans.map(\.disclosurePlan.claims), chapter: chapter)
    let current = currentKey.flatMap { key in key.isEmpty ? nil : world.volumes.first { $0.volume.jsEquals(key) } }
    let knowledge = plan?.knowledge
    let pov = plan.flatMap { ChatPack.present($0.pov) }
    let contextRefs = plan?.contextRefs ?? []
    let cast = castRefs(plan)
    var chapterCast = Set(pov.map { [JSString($0)] } ?? [])
    chapterCast.formUnion((knowledge?.pov ?? []).map { JSString($0) })
    chapterCast.formUnion(contextRefs.filter { $0.jsStartsWith("entity:") }.map { JSString($0.jsSlice("entity:".jsLength)) })

    let brief = try WriterRender.writerBrief(plan?.brief, canonFacts: world.facts, disclosure: &disclosure)
    let completedVolumes = try world.completedVolumes(chapter: chapter, current: current, disclosure: &disclosure)
    let openCanon = knowledge == nil ? try world.openCanon(chapterCast: chapterCast, disclosure: &disclosure) : nil

    let planTokens = countTokens(brief.chapterBrief) + countTokens(brief.endingContract)
    var pack = WriterRendered(
      reservations: [WriterReservation(name: "the chapter plan", tokens: planTokens, cap: WriterRender.Cap.chapterPlan, fromPlan: true)], omitted: openCanon?.omitted ?? [])
    let previous = try WriterRender.previousEnding(
      chapter: chapter - 1, row: world.final(chapter - 1).map { WriterEndingRow(finalized: true, isolated: $0.isolated, content: $0.body, summary: $0.summary) },
      draft: world.draft(chapter - 1).map { WriterEndingDraft(body: $0.body, summary: $0.summary, state: $0.state, isolated: $0.isolated, staleReason: $0.staleReason) },
      rawIsolated: rawIsolated, disclosure: &disclosure)
    pack.append(previous.reserved)

    if let current, let objective = ChatPack.present(current.objective) {
      let content = try disclosure.scrub(objective, .plan)
      pack.reserve(
        ChatPack.makeSection("volume_objective", content, tier: .approvedIntent, sourceRefs: ["volume:\(current.volume)"]).asStable, name: "the current volume's goal",
        cap: WriterRender.Cap.volumeGoal)
    }
    if let completedVolumes { pack.reserveDerived(completedVolumes, name: "the earlier volumes", cap: WriterRender.Cap.completedVolumes) }
    if let openCanon { pack.reserveDerived(openCanon.section, name: "the book rules (open canon)", cap: WriterRender.Cap.openCanon) }
    if let knowledge {
      let view = knowledgeView(in: disclosureWorld, chapter: chapter, contract: knowledge)
      pack.append(try WriterRender.knowledgeSections(view: view, chapterCast: chapterCast, disclosure: &disclosure))
    }
    pack.append(try WriterRender.allowedClues(disclosure: disclosure))

    let refs = chapterWriterRefs(plan)
    var resolution = WriterRefResolution()
    var characterRefs = Set<JSString>()
    var requiredCharacters = Set<JSString>()
    var refSections: [ChatPackSection] = []
    if !refs.isEmpty {
      resolution = try world.resolveRefs(refs, chapter: chapter, disclosure: &disclosure)
      let carried = Set(pack.sections.filter { carriedKeys.contains(JSString($0.key)) }.flatMap(\.sourceRefs).map { JSString($0) })
      characterRefs = Set(resolution.characters.map { JSString("ref:\($0)") })
      // context-assembler.service.ts:355 interpolates a missing POV as "null"
      let povRef = "entity:\(plan?.pov ?? "null")"
      let required = resolution.characters.filter { ref in contextRefs.contains { $0.jsEquals(ref) } && !ref.jsEquals(povRef) && !cast.contains { $0.jsEquals(ref) } }
      requiredCharacters = Set(required.prefix(WriterPackRender.fullCastMax).map { JSString("ref:\($0)") })
      refSections = resolution.resolved.filter { !$0.sourceRefs.contains { carried.contains(JSString($0)) } }
    }

    let povSection = try pov.flatMap { pov throws(DisclosureError) in try world.povSection(pov, disclosure: &disclosure) }
    if let pov, povSection == nil, !resolution.unresolved.contains(where: { $0.jsEquals("entity:\(pov)") }) { resolution.unresolved.append("entity:\(pov)") }

    let castKeys = Set(cast.map { JSString("ref:\($0)") })
    let entityCards = refSections.filter { $0.key.jsStartsWith("ref:entity:") && !$0.key.jsEquals(povSection?.key ?? "") }
    let entitySections = (povSection.map { [$0] } ?? []) + entityCards.filter { castKeys.contains(JSString($0.key)) } + entityCards.filter { !castKeys.contains(JSString($0.key)) }
    func place(_ card: ChatPackSection, priority: Int) {
      let stable = card.asStable
      let sheet = "\(WriterPackRender.sectionSubject(card))'s character sheet"
      if let povSection, card == povSection {
        pack.reserveDerived(stable, name: sheet, cap: WriterRender.Cap.povCard, fromPlan: true)
      } else if castKeys.contains(JSString(card.key)) || requiredCharacters.contains(JSString(card.key)) {
        pack.reserveDerived(stable, name: sheet, cap: WriterRender.Cap.castCard, fromPlan: true)
      } else {
        var optional = stable
        optional.priority = characterRefs.contains(JSString(card.key)) ? WriterRender.Priority.castCard : priority
        pack.sections.append(optional)
      }
    }

    for card in entitySections.prefix(WriterPackRender.fullCastMax) { place(card, priority: WriterRender.Priority.castCard) }
    for section in refSections where !section.key.jsStartsWith("ref:entity:") {
      var cited = section.asStable
      cited.priority = WriterRender.Priority.citedPage
      pack.sections.append(cited)
    }
    for section in try world.dynamicCastSections(entitySections, pov: pov, disclosure: &disclosure) {
      var state = section
      state.priority = WriterRender.Priority.castState
      pack.sections.append(state)
    }
    if let memory = try world.memorySection(chapter: chapter, rawIsolated: rawIsolated, disclosure: &disclosure) {
      pack.reserveDerived(memory, name: "the recent chapter summaries", cap: WriterRender.Cap.recentSummaries)
    }
    pack.reserveDerived(
      try WriterRender.writingStyleSection(world.writingStyle, disclosure: &disclosure).asStable, name: "the style guide", cap: WriterRender.Cap.writingStyle)
    for card in entitySections.dropFirst(WriterPackRender.fullCastMax) { place(card, priority: WriterRender.Priority.excessCard) }
    // Last of the core sections, so the author's decisions render next to the brief the template appends after the pack.
    pack.append(try WriterRender.writerLines(world.ledger, disclosure: &disclosure))
    return Composed(rendered: pack, planTokens: planTokens, brief: brief, unresolved: resolution.unresolved, withheld: resolution.withheld, disclosure: disclosure)
  }

  private struct Finished {
    var budgetTokens: Int
    var usedTokens: Int
    var sections: [ChatPackSection]
    var omitted: [ChatPackOmission]
    var renderedStable: String
    var renderedVolatile: String
    var rendered: String
  }

  /// `screen` holds the minor names of a permissive pack. The reference's forChapter passes no policy to finalizePack and screens at the router; screening the
  /// permissive pack here as well is a native-only defence.
  // apps/novel-forge-server/src/modules/ai/context/pack-finalize.ts:23 (finalizePack), with no plugin sections and nothing persisted
  private static func finalize(_ sections: [ChatPackSection], budgetTokens: Int, screen minorNames: [String]?, omitted: [ChatPackOmission]) throws(WriterPackError) -> Finished {
    let budgeted = applyBudget(sections, budgetTokens: budgetTokens)
    let fitting = budgeted.fitting
    if let minorNames {
      let screens = sectionScreens(fitting.map { ContextSection(key: $0.key, rendered: $0.rendered, sourceRefs: $0.sourceRefs) })
      if let hit = screenTexts(screens, lexicon: HardLineLexicon.standard.adding(minorNames: minorNames)) { throw .hardLine(hardLineError(hit)) }
    }
    let split = splitSegments(fitting)
    return Finished(
      budgetTokens: budgetTokens, usedTokens: fitting.reduce(0) { $0 + $1.tokens }, sections: fitting, omitted: omitted + budgeted.omitted.map(ChatPackOmission.init),
      renderedStable: split.renderedStable, renderedVolatile: split.renderedVolatile,
      rendered: joinSections(fitting.filter { $0.segment == .stable } + fitting.filter { $0.segment != .stable }))
  }
}
