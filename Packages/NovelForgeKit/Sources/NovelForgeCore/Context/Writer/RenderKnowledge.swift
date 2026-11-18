private let allowedCluesLead = "Signs you may show while their cause stays unexplained:"

extension WriterRender {
  // pack-render.ts:223
  static func sizedSectionCeiling(_ key: String, available: Int) -> Int {
    max(0, available - countTokens(renderSection(key, "")) - ChatPack.sizedSectionMargin)
  }

  struct FactCut: Equatable {
    var kept: [DisclosureFact]
    var omitted: [ChatPackOmission]
  }

  // pack-render.ts:89
  static func fitFacts(_ facts: [DisclosureFact], maxTokens: Int, line: (DisclosureFact) -> String) -> FactCut {
    var cut = FactCut(kept: [], omitted: [])
    var used = 0
    for fact in facts {
      let tokens = countTokens(line(fact)) + 1
      if used + tokens <= maxTokens || cut.kept.isEmpty {
        cut.kept.append(fact)
        used += tokens
      } else {
        cut.omitted.append(ChatPackOmission(key: "fact:\(fact.factKey)", reason: .budget, tokens: tokens))
      }
    }
    return cut
  }

  // pack-render.ts:106
  static func subjectsFirst(_ facts: [DisclosureFact], castKeys: Set<JSString>) -> [DisclosureFact] {
    func about(_ fact: DisclosureFact) -> Bool { (fact.subjects ?? []).contains { castKeys.contains(JSString($0)) } }
    return facts.filter(about) + facts.filter { !about($0) }
  }

  private static func refs(_ facts: [DisclosureFact]) -> [String] {
    facts.map { "fact:\($0.factKey)" }
  }

  /// What the point-of-view cast knows, this chapter's reveals, what only the reader knows and the behavioural constraints.
  // context-assembler.service.ts:282
  static func knowledgeSections(view: KnowledgeView, chapterCast: Set<JSString>, disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> WriterRendered {
    var rendered = WriterRendered()
    var learnedIn: [JSString: Int] = [:]
    for learned in view.learnedIn ?? [] { learnedIn[JSString(learned.factKey)] = learned.chapter }
    func isOpen(_ fact: DisclosureFact) -> Bool { learnedIn[JSString(fact.factKey)] == nil }
    let learned = view.known.filter { !isOpen($0) }.jsStableSorted { (learnedIn[JSString($0.factKey)] ?? 0) > (learnedIn[JSString($1.factKey)] ?? 0) }
    let known = fitFacts(
      subjectsFirst(view.known.filter(isOpen) + learned, castKeys: chapterCast), maxTokens: sizedSectionCeiling("known_facts", available: Cap.knownFacts)
    ) { renderKnownFacts([$0]) }
    rendered.omitted += known.omitted
    let knownSection = ChatPack.makeSection(
      "known_facts", try disclosure.scrub(renderKnownFacts(known.kept), .knowledge), tier: .canonical, sourceRefs: refs(known.kept))
    rendered.reserveDerived(knownSection, name: "what the point-of-view cast knows", cap: Cap.knownFacts)

    if !view.reveals.isEmpty {
      let reveals = ChatPack.makeSection(
        "chapter_reveals", try disclosure.scrub(renderChapterReveals(view.reveals), .knowledge), tier: .approvedIntent, sourceRefs: refs(view.reveals))
      rendered.reserve(reveals, name: "this chapter's reveals", cap: Cap.chapterReveals)
    }

    if !view.readerKnows.isEmpty {
      let readerKnows = fitFacts(
        subjectsFirst(view.readerKnows, castKeys: chapterCast), maxTokens: sizedSectionCeiling("reader_knows", available: Cap.readerKnows)
      ) { renderReaderKnows([$0], pov: view.pooledPov) }
      rendered.omitted += readerKnows.omitted
      let section = ChatPack.makeSection(
        "reader_knows", try disclosure.scrub(renderReaderKnows(readerKnows.kept, pov: view.pooledPov), .knowledge), tier: .canonical, sourceRefs: refs(readerKnows.kept))
      var fitted = ChatPack.fitToCap(section, cap: Cap.readerKnows)
      fitted.priority = Priority.readerKnows
      rendered.sections.append(fitted)
    }

    let hidden = fitFacts(
      subjectsFirst(withWriterNotes(view.hidden), castKeys: chapterCast), maxTokens: sizedSectionCeiling("hidden_constraints", available: Cap.hiddenConstraints)
    ) { renderHiddenConstraints([$0]) }
    rendered.omitted += hidden.omitted
    let constraints = try disclosure.scrub(renderHiddenConstraints(hidden.kept), .knowledge)
    if !constraints.isEmpty {
      let section = ChatPack.makeSection("hidden_constraints", constraints, tier: .approvedIntent, sourceRefs: refs(hidden.kept))
      rendered.reserveDerived(section, name: "the behavioural constraints", cap: Cap.hiddenConstraints)
    }
    return rendered
  }

  /// The author's licence to foreshadow, so it reaches the writer unscrubbed.
  // pack-render.ts:131
  static func allowedClues(disclosure: WriterDisclosurePolicy) throws(DisclosureError) -> WriterRendered {
    var rendered = WriterRendered()
    let clues = try disclosure.allowedClues()
    if clues.isEmpty { return rendered }
    let section = ChatPack.makeSection("allowed_clues", ([allowedCluesLead] + clues.map { "- \($0)" }).joined(separator: "\n"), tier: .approvedIntent)
    rendered.reserve(section, name: "the allowed clues", cap: Cap.allowedClues)
    return rendered
  }
}
