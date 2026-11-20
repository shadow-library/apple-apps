import ShadowText

private let labelMaxChars = 240

struct IdeaIdentity: Sendable {
  static let shared: IdeaIdentity? = QuoteRule.shared.map(IdeaIdentity.init)

  let quoteRule: QuoteRule

  // apps/novel-forge-server/src/modules/refinement/idea-id.ts:11
  private func canonical(_ value: OrderedJSON) -> OrderedJSON {
    switch value {
    case .string(let text): .string(quoteRule.normaliseForQuote(text))
    case .array(let items): .array(items.map(canonical))
    case .object(let record): .object(OrderedJSONObject(record.keys.jsSorted().compactMap { key in record[key].map { (key: key, value: canonical($0)) } }))
    case .null, .bool, .int, .double: value
    }
  }

  // apps/novel-forge-server/src/modules/refinement/idea-id.ts:28
  func ideaId(of op: ChangeOp) -> String {
    let fields = opFields(op)
    let content = declaredOpFields(op.type).compactMap { field in fields[field].map { (key: field, value: $0) } }
    let identity = OrderedJSONObject([(key: "op", value: .string(op.type.rawValue))] + content)
    return String(sha256Hex(canonical(.object(identity)).jsonText).prefix(24))
  }

  // apps/novel-forge-server/src/modules/refinement/idea-id.ts:37
  func stampIdeaIds(_ ops: [ChangeOp]) -> [ChangeOp] {
    ops.map { op in
      var metadata = op.metadata
      metadata.ideaId = isActionOp(op) ? nil : ideaId(of: op)
      return ChangeOp(operation: op.operation, metadata: metadata)
    }
  }
}

// apps/novel-forge-server/src/modules/refinement/idea-id.ts:40
private func clip(_ text: String) -> String {
  let flat = text.jsReplace(ProseRegex.whitespaceRunGlobal, " ").jsTrim()
  return flat.jsLength > labelMaxChars ? flat.jsSlice(0, labelMaxChars - 1) + "…" : flat
}

// apps/novel-forge-server/src/modules/refinement/idea-id.ts:45
private func withText(_ head: String, _ texts: String?...) -> String {
  guard let text = texts.compactMap({ $0 }).first(where: { !$0.jsTrim().isEmpty }) else { return head }
  return "\(head): \(clip(text))"
}

// apps/novel-forge-server/src/modules/refinement/idea-id.ts:51
func ideaLabel(_ op: ChangeOp) -> String? {
  switch op.operation {
  case .premiseUpdate(let premise):
    let themes = premise.themes?.joined(separator: ", ")
    return withText(
      "Story", premise.premise, premise.brief, themes, premise.instructions, premise.theme, premise.readerPromise, premise.protagonistKey, premise.opposition)
  case .bibleDocumentUpsert(let page):
    let address = BibleDocAddress(section: page.section.rawValue, slug: page.slug)
    let head = "Page \(page.section.rawValue)/\(page.slug)"
    return isWriterExcludedBibleDoc(address) ? head : withText(head, page.body)
  case .bibleDocumentRemove(let page): return "Remove page \(page.section.rawValue)/\(page.slug)"
  case .volumeUpsert(let volume): return withText("Volume \(volume.volumeKey)", volume.title, volume.objective)
  case .volumeRemove(let volume): return "Remove volume \(volume.volumeKey)"
  case .briefUpdate(let brief): return withText("Plan for chapter \(brief.chapter)", brief.title, brief.chapterPurpose, brief.direction.value)
  case .briefRemove(let brief): return "Remove the plan for chapter \(brief.chapter)"
  case .draftUpdate(let draft): return withText("Rewrite of chapter \(draft.chapter)", draft.title)
  case .draftRemove(let draft): return "Remove the draft of chapter \(draft.chapter)"
  case .draftRewritePassage(let draft): return withText("Passage rewrite in chapter \(draft.chapter)", draft.label)
  case .entityUpsert(let entity):
    return withText("\(entity.name ?? entity.entityKey) (\(entity.type.rawValue))", entity.motivation, entity.status, entity.notes, entity.body)
  case .entityRemove(let entity): return "Remove \(entity.entityKey)"
  case .factUpsert(let fact): return "Secret \(fact.factKey)"
  case .factRemove(let fact): return "Remove secret \(fact.factKey)"
  case .milestoneUpsert(let milestone): return withText("Milestone \(milestone.milestoneKey)", milestone.label)
  case .milestoneRemove(let milestone): return "Remove milestone \(milestone.milestoneKey)"
  case .promiseCreate(let promise): return withText("Promise \(promise.key)", promise.label)
  case .promiseUpdate(let promise): return withText("Promise \(promise.key)", promise.label)
  case .promiseSetPayoff(let promise): return "Payoff for promise \(promise.key)"
  case .promiseDrop(let promise): return "Drop promise \(promise.key)"
  case .organiseRule(let rule): return withText("Rule", rule.rule)
  case .actionGenerateChapter, .actionAuditBible, .actionEnhancePremise, .actionJudgeDraft, .actionReviseDraft, .actionApproveDraft, .actionApplyContinuity, .actionValidate,
    .actionFinalize, .actionOrganiseNotes, .actionPlanChapter, .actionAdvanceVolume:
    return nil
  }
}
