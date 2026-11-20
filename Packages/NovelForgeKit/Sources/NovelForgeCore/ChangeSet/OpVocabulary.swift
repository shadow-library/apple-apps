import ShadowText

private let rationaleNote =
  "rationale, on any op, is one short sentence saying why that change is being made. It is shown to the author beside the op when they review the proposal and is never written into the story itself."

private let quoteNote =
  "quote, on any op, is the exact words from the author's message in this turn that the op records — copied character for character, never paraphrased, shortened with an ellipsis, or taken from an earlier message or your own reply. The server decides whether an op with a quote the author really wrote applies: it must only record what they said, stated rather than asked or hedged. Every other op becomes a suggestion card the author accepts or declines. Give a quote only when the op states what the author said, and leave it out of your own ideas."

private func contractShape() -> String {
  let hookTypes = HookType.allCases.map(\.rawValue).joined(separator: " | ")
  return "\n"
    + #"endingContract, when present, must be exactly: {"hookType": <one of: \#(hookTypes)>, "emotionalBeat": <non-empty string>, "openQuestion": <non-empty string>, "handoffState": <non-empty string>, "mustNotResolve": <string[], optional>} — hookType is an enum, never free text."#
}

private let knowledgeShape =
  "\n"
  + #"knowledgeContract, when present, must be exactly: {"pov": <non-empty array of entity keys>, "learns": <optional array of {"entityKey": <string>, "factKey": <string>}>} — pov bounds what the chapter may state; learns names the facts discovered on-page. A chapter that reveals nothing previously hidden omits the contract entirely; pass null to drop one the brief already carries."#

private let factRules =
  "\n"
  + #"Canon facts are the spoiler ledger: a truth the reader must not learn yet goes in fact.upsert body and NEVER in bible prose, an entity sheet, or a brief — those are visible to the drafter. constraintNote is an author-only note the drafter never sees; writerNote is the writer-safe instruction the drafter gets while the fact is hidden — it must never state or hint at the truth, and without one the fact is withheld from the drafter entirely; terms are the give-away names and phrases the leak scan blocks. In a mystery the reveal schedule IS the plot, so place each reveal deliberately: set revealChapter as the intended beat and stage the matching brief.update knowledgeContract.learns that pays it off. Omit revealChapter to leave the schedule alone; pass null to undate the fact — an undated fact without an unlock stays hidden and no plan may reveal it. unlock, when present, is {"all": [<one of {"milestone": <key>} | {"volume": <key>} | {"chapter": <number>} | {"ending": true}>, ...]} — the fact may be revealed only once every term holds; allowedClues are observable effects the writer may show while the explanation stays hidden. Omit either to keep it; pass null to clear it."#

private let vocabularyHeader = "changeSet, when present, must be an ARRAY of operation objects. Allowed operations and their fields:"

private let actionHeader =
  "Action operations may appear in the same changeSet array; they run the pipeline instead of editing content. Use one only when the author asks for that work to happen:"

private func renderLine(_ op: OpType, options: OpVocabularyOptions, purposeSuffix: Bool) -> String {
  let spec = op.spec
  let hidden = modelHiddenFields(op, options)
  let required = spec.required.map { "\"\($0.name)\": <\($0.kind.rawValue), required>" }
  let optional = spec.optional.filter { field in !hidden.contains { $0.jsEquals(field.name) } }.map { "\"\($0.name)\": <\($0.kind.rawValue), optional>" }
  let fields = (required + optional).map { ", \($0)" }.joined()
  let tail = (purposeSuffix ? op.purpose : spec.description).map { " — \($0)" } ?? ""
  return "- {\"op\": \"\(op.rawValue)\"\(fields)}\(tail)"
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-vocabulary.ts:35
func renderOpVocabulary(_ ops: [OpType], _ options: OpVocabularyOptions = OpVocabularyOptions()) -> String {
  let lines = ops.map { renderLine($0, options: options, purposeSuffix: false) }
  let hasBrief = ops.contains(.briefUpdate)
  let sections = [
    options.quotes ? "\n" + quoteNote : "",
    hasBrief ? contractShape() : "",
    hasBrief ? knowledgeShape : "",
    ops.contains(.factUpsert) ? factRules : "",
  ]
  return "\(vocabularyHeader)\n\(lines.joined(separator: "\n"))\n\(rationaleNote)" + sections.joined()
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-vocabulary.ts:59
func renderActionVocabulary(_ actions: [OpType]) -> String {
  let lines = actions.map { renderLine($0, options: OpVocabularyOptions(), purposeSuffix: true) }
  return "\(actionHeader)\n\(lines.joined(separator: "\n"))"
}
