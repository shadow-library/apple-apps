enum ChatLookupName: String, CaseIterable, Sendable {
  case getEntity = "get_entity"
  case getChapterSummaries = "get_chapter_summaries"
  case getPlotThreads = "get_plot_threads"
  case getBibleDocument = "get_bible_document"
  case getVolume = "get_volume"
  case getBrief = "get_brief"
  case getDraft = "get_draft"
  case getCanonFacts = "get_canon_facts"
  case getNotes = "get_notes"
  case getUsage = "get_usage"
}

struct ChatLookupDefinition: Equatable, Sendable {
  let name: ChatLookupName
  let description: String
  /// Nil where the reference's schema is not a plain object, so the playbook says "see description".
  let arguments: [String]?
  let maxCallsPerRun: Int
  let tokensBudget: Int
  let schema: OrderedJSON

  var tool: ChatLookupTool { ChatLookupTool(name: name.rawValue, arguments: arguments, description: description) }
  var characterLimit: Int { tokensBudget * 4 }
}

private func schema(_ properties: [(String, OrderedJSON)], required: [String]) -> OrderedJSON {
  .object(
    OrderedJSONObject([
      (key: "type", value: .string("object")),
      (key: "properties", value: .object(OrderedJSONObject(properties.map { (key: $0.0, value: $0.1) }))),
      (key: "required", value: .array(required.map(OrderedJSON.string))),
      (key: "additionalProperties", value: .bool(false)),
    ]))
}

private func property(_ type: String, _ extra: [(String, OrderedJSON)] = []) -> OrderedJSON {
  .object(OrderedJSONObject([(key: "type", value: .string(type))] + extra.map { (key: $0.0, value: $0.1) }))
}

private func choices(_ values: [String]) -> OrderedJSON {
  property("string", [("enum", .array(values.map(OrderedJSON.string)))])
}

private let positiveInteger = property("integer", [("minimum", .int(1))])

enum ChatLookups {
  // apps/novel-forge-server/src/modules/ai/tools/tool-registry.service.ts:25 filtered to the chat hub; search_lore, search_prose, get_world_facts, get_character_timeline and get_review stay out
  static let definitions: [ChatLookupDefinition] = [
    ChatLookupDefinition(
      name: .getEntity,
      // tools/get-entity.tool.ts:16
      description: "Retrieve an entity card by entity key: name, type, status and body (or notes).", arguments: ["entityKey"],
      maxCallsPerRun: 15, tokensBudget: 3500, schema: schema([("entityKey", property("string"))], required: ["entityKey"])),
    ChatLookupDefinition(
      name: .getChapterSummaries,
      // tools/get-chapter-summaries.tool.ts:20
      description: "Retrieve chapter summaries for a range of chapters (max 20-chapter span).", arguments: nil, maxCallsPerRun: 5, tokensBudget: 8000,
      schema: schema([("from", positiveInteger), ("to", positiveInteger)], required: ["from", "to"])),
    ChatLookupDefinition(
      name: .getPlotThreads,
      // tools/get-plot-threads.tool.ts:17
      description: "Retrieve plot threads (promises), optionally filtered by status (open, closed, or dropped).", arguments: ["status"], maxCallsPerRun: 5, tokensBudget: 4000,
      schema: schema([("status", choices(["closed", "open", "dropped"]))], required: [])),
    ChatLookupDefinition(
      name: .getBibleDocument,
      // tools/get-bible-document.tool.ts:16
      description: "Retrieve the full body of a bible document by section and slug, including its frontmatter and revision. Use before proposing bible_document.upsert.",
      arguments: ["section", "slug"], maxCallsPerRun: 10, tokensBudget: 6000,
      schema: schema([("section", choices(BiblePageSection.allCases.map(\.rawValue))), ("slug", property("string"))], required: ["section", "slug"])),
    ChatLookupDefinition(
      name: .getVolume,
      // tools/get-volume.tool.ts:13
      description: "Retrieve the full volume record by volume key: title, goal and notes. Use before proposing volume.upsert.", arguments: ["volumeKey"], maxCallsPerRun: 10,
      tokensBudget: 2000, schema: schema([("volumeKey", property("string"))], required: ["volumeKey"])),
    ChatLookupDefinition(
      name: .getBrief,
      // tools/get-brief.tool.ts:13
      description: "Retrieve the full brief for a chapter, including its ending contract and knowledge contract. Use before proposing brief.update.", arguments: ["chapter"],
      maxCallsPerRun: 8, tokensBudget: 5000, schema: schema([("chapter", positiveInteger)], required: ["chapter"])),
    ChatLookupDefinition(
      name: .getDraft,
      // tools/get-draft.tool.ts:17
      description:
        "Retrieve a chapter draft: title, status, revision, summary and body (an isolated, unrestricted chapter returns its header and approved bridge summary only). Use before proposing draft.update.",
      arguments: ["chapter"], maxCallsPerRun: 2, tokensBudget: 10000, schema: schema([("chapter", positiveInteger)], required: ["chapter"])),
    ChatLookupDefinition(
      name: .getCanonFacts,
      // tools/get-canon-facts.tool.ts:15
      description: "Retrieve canon facts and secrets by key: the truth, when the reader may learn it, the cover note for the writer, its give-away terms and allowed clues.",
      arguments: ["keys"], maxCallsPerRun: 4, tokensBudget: 4000,
      schema: schema(
        [("keys", property("array", [("items", property("string", [("minLength", .int(1))])), ("minItems", .int(1)), ("maxItems", .int(20))]))], required: ["keys"])),
    ChatLookupDefinition(
      name: .getNotes,
      // tools/get-notes.tool.ts:108
      description:
        "Read the author's own notes verbatim, numbered by paragraph (a long paragraph comes in parts, ¶3.2). `from` and `part` say where to start; `query` keeps only the paragraphs containing that text. Use before quoting, organising or critiquing them.",
      arguments: ["from", "part", "query"], maxCallsPerRun: 4, tokensBudget: 4500,
      schema: schema([("from", positiveInteger), ("part", positiveInteger), ("query", property("string", [("minLength", .int(1))]))], required: [])),
    ChatLookupDefinition(
      name: .getUsage,
      // tools/get-usage.tool.ts:80
      description:
        "Retrieve the project's AI usage — cost, tokens and calls — for a period (today, week, month, all), with a per-role breakdown and whether the figures are estimated. Read-only; carries no prompt or answer content.",
      arguments: ["period"], maxCallsPerRun: 5, tokensBudget: 2000,
      schema: schema([("period", choices(UsagePeriod.allCases.map(\.rawValue)))], required: [])),
  ]

  static let tools: [ChatLookupTool] = definitions.map(\.tool)

  static func definition(named name: String) -> ChatLookupDefinition? {
    definitions.first { $0.name.rawValue.jsEquals(name) }
  }
}
