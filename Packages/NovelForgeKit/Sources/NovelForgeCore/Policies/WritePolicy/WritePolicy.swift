struct WritePolicy: Sendable {
  static let shared: WritePolicy? = QuoteRule.shared.map(WritePolicy.init)

  private struct FieldTokens {
    let written: Set<QuoteToken>
    let before: Set<QuoteToken>
  }

  private struct Judged {
    let op: ChangeOp
    var disposition: OpDisposition
    var verdict: CardReason?
  }

  let quoteRule: QuoteRule

  /// The reference has no policy that failed to build; this one applies nothing then, holding the whole turn for review.
  static func split(_ input: WritePolicyInput, with policy: WritePolicy? = shared) -> ChangeSetSplit {
    if let policy { return policy.splitChangeSet(input) }
    return ChangeSetSplit(
      ops: input.ops,
      direct: [],
      cards: input.ops,
      sources: [],
      dispositions: input.ops.indices.map { .card(index: $0, reason: .heldForReview, rule: nil) },
      held: input.ops.isEmpty ? .none : .turn
    )
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:302
  func launders(_ op: ChangeOp, _ current: WritePolicyRecordFields?, _ vocabulary: String) -> Bool {
    launders(op, current, words: quoteRule.authorWords(vocabulary))
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:308
  func exceedsNoveltyBudget(_ op: ChangeOp, _ current: WritePolicyRecordFields?, _ vocabulary: String) -> Bool {
    exceedsNoveltyBudget(op, current, words: quoteRule.authorWords(vocabulary))
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:315
  func exceedsRemovalBudget(_ op: ChangeOp, _ current: WritePolicyRecordFields?) -> Bool {
    fieldTokens(op, current).contains { field in
      Double(field.before.subtracting(field.written).count) > max(WritePolicyTables.removalFloor, Double(field.before.count) * WritePolicyTables.budgetShare)
    }
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:488
  func splitChangeSet(_ input: WritePolicyInput) -> ChangeSetSplit {
    let override = overrideReason(input)
    let hold = override == nil ? input.hold : .none
    let appliesIdeas = override == nil && input.ideas == .apply
    let words = quoteRule.authorWords(input.vocabulary ?? input.authorMessage)
    let judged = judge(input, words, appliesIdeas: appliesIdeas, hold: hold)
    let unheld = hold == .none ? judged : judge(input, words, appliesIdeas: appliesIdeas, hold: .none)

    let dispositions = judged.map { entry -> OpDisposition in
      guard let override, entry.disposition.side == .direct else { return entry.disposition }
      return .card(index: entry.disposition.index, reason: override, rule: nil)
    }
    let turned = zip(unheld, dispositions).contains { $0.disposition.side == .direct && $1.side == .card }
    let sides = zip(input.ops, dispositions)
    return ChangeSetSplit(
      ops: input.ops,
      direct: sides.filter { $1.side == .direct }.map(\.0),
      cards: sides.filter { $1.side == .card }.map(\.0),
      sources: dispositions.compactMap { disposition in
        guard case .direct(_, let source) = disposition else { return nil }
        return source
      },
      dispositions: dispositions,
      held: turned ? hold : .none
    )
  }

  private func launders(_ op: ChangeOp, _ current: WritePolicyRecordFields?, words: AuthorWords) -> Bool {
    novelTokens(fieldTokens(op, current), words).contains { words.hedged.contains($0) }
  }

  private func exceedsNoveltyBudget(_ op: ChangeOp, _ current: WritePolicyRecordFields?, words: AuthorWords) -> Bool {
    let tokens = fieldTokens(op, current)
    let written = Set(tokens.flatMap(\.written))
    return Double(novelTokens(tokens, words).count) > max(WritePolicyTables.noveltyFloor, Double(written.count) * WritePolicyTables.budgetShare)
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:252
  private static func quoteText(of value: OrderedJSON?) -> String {
    switch value {
    case .string(let text): text
    case .array(let items): items.map { quoteText(of: $0) }.joined(separator: " ")
    case .object(let record): record.entries.map { quoteText(of: $0.value) }.joined(separator: " ")
    default: ""
    }
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:283
  private func fieldTokens(_ op: ChangeOp, _ current: WritePolicyRecordFields?) -> [FieldTokens] {
    let fields = opFields(op)
    let displayed = WritePolicyTables.displayKeyFields.flatMap { field in quoteRule.contentTokens(Self.quoteText(of: fields[field] ?? current?[field])) }
    let identifiers = WritePolicyTables.identifierKeyFields.flatMap { field in quoteRule.contentTokens(Self.quoteText(of: current?[field])) }
    let own = Set(displayed + identifiers)
    return op.type.textFields.filter { fields[$0] != nil }.map { field in
      FieldTokens(
        written: Set(quoteRule.contentTokens(Self.quoteText(of: fields[field])).filter { !own.contains($0) }),
        before: Set(quoteRule.contentTokens(Self.quoteText(of: current?[field])).filter { !own.contains($0) })
      )
    }
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:297
  private func novelTokens(_ tokens: [FieldTokens], _ words: AuthorWords) -> Set<QuoteToken> {
    Set(tokens.flatMap { field in field.written.filter { !words.stated.contains($0) && !field.before.contains($0) } })
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:404
  private func quoteVerdict(_ op: ChangeOp, _ current: WritePolicyRecordFields?, _ input: WritePolicyInput, _ words: AuthorWords) -> CardReason? {
    guard op.type.isDirectKind else { return .notAllowlisted }
    guard let quote = op.metadata.quote, !quote.jsTrim().isEmpty else { return .noQuote }
    guard quoteRule.quoteFoundIn(quote, input.authorMessage) else { return .quoteNotFound }
    if quoteRule.quoteIsTentative(quote, input.authorMessage) || launders(op, current, words: words) { return .tentative }
    if exceedsRemovalBudget(op, current) { return .removal }
    if exceedsNoveltyBudget(op, current, words: words) { return .novelContent }
    return nil
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:429
  private func intrinsicDisposition(_ op: ChangeOp, _ index: Int, _ input: WritePolicyInput, _ words: AuthorWords, appliesIdeas: Bool) -> Judged {
    if let rule = alwaysCardRule(op, input.state) { return Judged(op: op, disposition: .card(index: index, reason: .alwaysCard, rule: rule)) }
    let current = input.state.fields(of: changeSetRefs([op]).first)
    guard let verdict = quoteVerdict(op, current, input, words) else { return Judged(op: op, disposition: .direct(index: index, source: .quoted)) }
    if !appliesIdeas { return Judged(op: op, disposition: .card(index: index, reason: verdict, rule: nil)) }
    if let ideaRule = ideaCardRule(op) { return Judged(op: op, disposition: .card(index: index, reason: verdict, rule: ideaRule)) }
    if exceedsRemovalBudget(op, current) { return Judged(op: op, disposition: .card(index: index, reason: .removal, rule: nil)) }
    return Judged(op: op, disposition: .direct(index: index, source: .idea), verdict: verdict)
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:444
  private func awaitsCardEntities(_ op: ChangeOp, _ directTypes: Set<EntityType>, _ cardTypes: Set<EntityType>) -> Bool {
    guard case .bibleDocumentUpsert(let page) = op.operation, let body = page.body, !body.jsTrim().isEmpty else { return false }
    let required = requiredEntityTypesForSlug(section: page.section.rawValue, slug: page.slug)
    return !required.isEmpty && !required.contains(where: directTypes.contains) && required.contains(where: cardTypes.contains)
  }

  private func entityTypes(_ judged: [Judged], _ side: OpSide) -> Set<EntityType> {
    Set(
      judged.filter { $0.disposition.side == side }.compactMap { entry in
        guard case .entityUpsert(let entity) = entry.op.operation else { return nil }
        return entity.type
      }
    )
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:451
  private func moveDependentsToCards(_ judged: inout [Judged], _ state: WritePolicyState) {
    func created(_ op: ChangeOp) -> [String] { changeSetRefs([op]).filter { !state.has($0) } }
    var createdByCards = Set(judged.filter { $0.disposition.side == .card }.flatMap { created($0.op) }.map { JSString($0) })

    var moved = true
    while moved {
      moved = false
      for position in judged.indices where judged[position].disposition.side == .direct {
        let op = judged[position].op
        let namesCardRecord = (changeSetRefs([op]) + opReferences(op)).contains { createdByCards.contains(JSString($0)) }
        if !namesCardRecord, !awaitsCardEntities(op, entityTypes(judged, .direct), entityTypes(judged, .card)) { continue }
        judged[position].disposition = .card(index: judged[position].disposition.index, reason: judged[position].verdict ?? .dependsOnCard, rule: nil)
        for ref in created(op) { createdByCards.insert(JSString(ref)) }
        moved = true
      }
    }
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:474
  private func judge(_ input: WritePolicyInput, _ words: AuthorWords, appliesIdeas: Bool, hold: WriteHold) -> [Judged] {
    var judged = input.ops.enumerated().map { (index: Int, op: ChangeOp) -> Judged in
      let held = hold == .turn || (hold == .writerRead && !isPlannerSide(op))
      let intrinsic = intrinsicDisposition(op, index, input, words, appliesIdeas: appliesIdeas && !held)
      return held && intrinsic.disposition.side == .direct ? Judged(op: op, disposition: .card(index: index, reason: .heldForReview, rule: nil)) : intrinsic
    }
    moveDependentsToCards(&judged, input.state)
    return judged
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:511
  private func overrideReason(_ input: WritePolicyInput) -> CardReason? {
    if input.justDiscussing { return .justDiscussing }
    return input.mode == .auto ? nil : .manualMode
  }
}
