import ShadowText

struct WriterEndingRow: Equatable, Sendable {
  var finalized: Bool
  var isolated: Bool
  var content: String?
  var summary: String?
}

struct WriterEndingDraft: Equatable, Sendable {
  var body: String?
  var summary: String?
  var state: OrderedJSON?
  var isolated: Bool
  var staleReason: String?
}

struct WriterEndingCaps: Equatable, Sendable {
  var ending: Int
  var state: Int

  static let writer = WriterEndingCaps(ending: WriterRender.Cap.prevEnding, state: WriterRender.Cap.continuationState)
}

struct WriterPreviousEnding: Equatable, Sendable {
  var ending: ChatPackSection?
  var state: ChatPackSection?

  var reserved: WriterRendered {
    var rendered = WriterRendered()
    if let ending { rendered.reserveDerived(ending, name: "the previous chapter's ending", cap: WriterRender.Cap.prevEnding) }
    if let state { rendered.reserveDerived(state, name: "the continuation state", cap: WriterRender.Cap.continuationState) }
    return rendered
  }
}

private let establishedFactsMax = 15

extension OrderedJSON {
  fileprivate var isTruthy: Bool {
    switch self {
    case .null: false
    case .bool(let flag): flag
    case .int(let number): number != 0
    case .double(let number): number != 0 && !number.isNaN
    case .string(let text): !text.isEmpty
    case .array, .object: true
    }
  }
}

extension WriterRender {
  // pack-render.ts:282
  private static func scrubbedTail(_ prose: String, disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> String {
    try disclosure.scrub(truncateAtParagraphTail(prose, maxTokens: ChatPack.previousEndingTail * 2).text, .prose)
  }

  // pack-render.ts:286
  private static func renderCarriedState(_ state: OrderedJSON, disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> String {
    if case .string(let text) = state { return try disclosure.scrub(text, .state) }
    return try disclosure.scrubState(state, establishedFactsMax: establishedFactsMax).jsonText
  }

  /// Shortened a whole entry at a time so it stays valid JSON: the largest entry goes first, and a list loses its last item rather than all of them.
  // pack-render.ts:296
  private static func fittedState(_ state: OrderedJSON, disclosure: inout WriterDisclosurePolicy, maxTokens: Int) throws(DisclosureError) -> String {
    if case .string = state { return try renderCarriedState(state, disclosure: &disclosure) }
    let scrubbed = try disclosure.scrubState(state, establishedFactsMax: establishedFactsMax)
    switch scrubbed {
    case .array(var items):
      while !items.isEmpty && countTokens(OrderedJSON.array(items).jsonText) > maxTokens { items.removeLast() }
      return OrderedJSON.array(items).jsonText
    case .object(let object):
      var entries = object.entries.map { (key: $0.key, value: $0.value) }
      var text = scrubbed.jsonText
      while countTokens(text) > maxTokens && !entries.isEmpty {
        var largest = 0
        for index in entries.indices.dropFirst() where entries[index].value.jsonText.jsLength > entries[largest].value.jsonText.jsLength { largest = index }
        if case .array(let items) = entries[largest].value, items.count > 1 {
          entries[largest].value = .array(Array(items.dropLast()))
        } else {
          entries.remove(at: largest)
        }
        text = OrderedJSON.object(OrderedJSONObject(entries)).jsonText
      }
      return text
    default:
      return try renderCarriedState(state, disclosure: &disclosure)
    }
  }

  // pack-render.ts:317
  private static func renderIsolatedEnding(_ summary: String?, state: OrderedJSON?, disclosure: inout WriterDisclosurePolicy, maxTokens: Int) throws(DisclosureError) -> String {
    let scrubbed = try disclosure.scrub(summary ?? "", .summary)
    let half = Int((Double(maxTokens) / 2).rounded(.down))
    let head = "Summary: \(truncateAtParagraph(scrubbed, maxTokens: half).text)\nState: "
    guard let state, state.isTruthy else { return head + "null" }
    return head + (try fittedState(state, disclosure: &disclosure, maxTokens: maxTokens - countTokens(head)))
  }

  /// An isolated chapter has no approved bridge here (isolation bridges are out of phase 7), so only the unrestricted writer reads its summary and state.
  // pack-render.ts:348
  static func previousEnding(
    chapter: Int, row: WriterEndingRow?, draft: WriterEndingDraft?, rawIsolated: Bool, disclosure: inout WriterDisclosurePolicy, caps: WriterEndingCaps = .writer
  ) throws(DisclosureError) -> WriterPreviousEnding {
    let refs = ["chapter:\(chapter)"]
    let stale = draft?.staleReason != nil ? "\(ChatPack.staleLabel)\n" : ""
    let isolated = row?.isolated == true || draft?.isolated == true
    let carried = isolated && !rawIsolated ? nil : draft?.state.flatMap { $0 == .null ? nil : $0 }
    let endingRoom = sizedSectionCeiling("prev_ending", available: caps.ending)

    func isolatedEnding(_ summary: String?, room: Int, _ disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> String {
      guard rawIsolated else { return ChatPack.noApprovedBridge }
      return try renderIsolatedEnding(summary, state: carried, disclosure: &disclosure, maxTokens: room)
    }

    var found: ChatPackSection?
    if let row {
      let tier: ChatPackTier = row.finalized ? .canonical : .working
      if row.isolated {
        found = ChatPack.makeSection("prev_ending", try isolatedEnding(row.summary, room: endingRoom, &disclosure), tier: tier, sourceRefs: refs)
      } else {
        found = ChatPack.makeSectionTail(
          "prev_ending", try scrubbedTail(row.content ?? "", disclosure: &disclosure), maxTokens: ChatPack.previousEndingTail, tier: tier, sourceRefs: refs)
      }
    } else if let draft, draft.isolated {
      let label = "\(ChatPack.draftLabel)\(stale)"
      let body = try isolatedEnding(draft.summary, room: endingRoom - countTokens(label), &disclosure)
      found = ChatPack.makeSection("prev_ending", label + body, tier: .working, sourceRefs: refs)
    } else if let body = ChatPack.present(draft?.body) {
      let cut = truncateAtParagraphTail(try scrubbedTail(body, disclosure: &disclosure), maxTokens: ChatPack.previousEndingTail)
      let rendered = renderSection("prev_ending", "\(ChatPack.draftLabel)\(stale)\(cut.text)")
      found = ChatPackSection(
        key: "prev_ending", tier: .working, segment: .volatile, tokens: countTokens(rendered), truncated: cut.truncated, sourceRefs: refs, rendered: rendered)
    }

    var state: ChatPackSection?
    if let carried {
      let text = try fittedState(carried, disclosure: &disclosure, maxTokens: sizedSectionCeiling("continuation_state", available: caps.state) - countTokens(stale))
      state = ChatPack.fitToCap(ChatPack.makeSection("continuation_state", stale + text, tier: .working, sourceRefs: refs), cap: caps.state)
    }
    return WriterPreviousEnding(ending: found.map { ChatPack.fitToCap($0, cap: caps.ending) }, state: state)
  }
}
