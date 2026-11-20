import ShadowText

private let underscores = builtInPattern("_", flags: "g")
private let chapterPrefix = "chapter:"

private let refLabels: [JSString: @Sendable (String) -> String] = [
  "chapter": { "Chapter \($0)'s summary" },
  "entity": { "The Story Bible entry \"\($0)\"" },
  "bible_doc": { "The Bible page \"\($0)\"" },
  "fact": { "The canon fact \"\($0)\"" },
  "world_fact": { "The world fact \"\($0)\"" },
  "thread": { "The plot thread \"\($0)\"" },
  "mystery": { "The mystery \"\($0)\"" },
  "volume": { "Volume \"\($0)\"'s goal" },
  "doc": { "The Bible page \"\($0)\"" },
]

// apps/novel-forge-server/src/modules/ai/hard-line.ts:126
func describeSection(_ key: String, sourceRefs: [String]) -> String {
  if key.jsEquals("brief") {
    let chapter = sourceRefs.first { $0.jsStartsWith(chapterPrefix) }?.jsSlice(chapterPrefix.jsLength) ?? ""
    return chapter.isEmpty ? "The chapter plan" : "Chapter \(chapter)'s plan"
  }
  for ref in sourceRefs {
    let colon = ref.jsIndexOf(":")
    guard colon != -1, let label = refLabels[JSString(ref.jsSlice(0, colon))] else { continue }
    return label(ref.jsSlice(colon + 1))
  }
  return "The story context's \(key.jsReplace(underscores, " ")) section"
}

private let suppliedInputs: [JSString: String] = [
  "userMessage": "Your message",
  "message": "Your message",
  "guidance": "The guidance for this chapter",
  "feedback": "The revision note",
  "chapterBrief": "The chapter plan",
  "endingContract": "The chapter plan",
  "instructions": "The art instructions",
  "note": "The note",
  "projectBrief": "The novel's brief",
  "overview": "The novel's overview",
  "extraContext": "The planning notes",
  "authorIntent": "What you said happens in the chapter",
  "chosenDirection": "The direction you chose",
  "authorNotes": "Your notes",
  "settledFindings": "The findings you settled",
  "subjectLabel": "The illustration subject",
  "references": "The reference images",
]

private let backgroundInputs: [JSString: String] = {
  let storyContext = ["contextPack", "stableContext", "volatileContext", "catalog", "obligations", "milestones", "task"]
  let earlierConversation = ["history", "rounds", "transcript", "priorSummary"]
  let chapterText = ["prose", "body", "draftBody", "passage", "chapterProse"]
  let storyBible = ["foundation", "world", "power", "factionsAndLocations", "characters", "plot", "priorSections", "docInventory", "entityInventory", "manifest", "material"]
  let instructions = [
    "scopeInstructions", "turnRules", "section", "scope", "subjectType", "chapterNumber", "endingNote", "startChapter", "endChapter", "minScenes", "wordTargetMin", "wordTargetAim",
    "wordTargetMax", "draftWords", "minWords", "aimWords", "missingWords",
  ]
  var table: [JSString: String] = [:]
  for (label, keys) in [
    ("The story context", storyContext), ("The earlier conversation", earlierConversation), ("The chapter text", chapterText), ("The Story Bible", storyBible),
    ("The instructions", instructions),
  ] {
    for key in keys { table[JSString(key)] = label }
  }
  table["chapterSummary"] = "The chapter summary"
  table["existingTitles"] = "The chapter titles"
  table["findings"] = "The review findings"
  return table
}()

// apps/novel-forge-server/src/modules/ai/hard-line.ts:208
func isClassifiedInput(_ key: String) -> Bool {
  suppliedInputs[JSString(key)] != nil || backgroundInputs[JSString(key)] != nil
}

private let creativeRoles: Set<JSString> = ["generation", "fix", "revision", "chat"]

// apps/novel-forge-server/src/modules/ai/hard-line.ts:215
func outputScope(role: String) -> HardLineScope {
  creativeRoles.contains(JSString(role)) ? .supplied : .background
}

extension HardLineContent {
  init(json: OrderedJSON?) {
    switch json {
    case .string(let text)?: self = .text(text)
    case .array(let items)?: self = .parts(items.map { HardLineContentPart(text: $0.stringValue ?? $0.objectValue?["text"]?.stringValue) })
    default: self = .other
    }
  }

  // apps/novel-forge-server/src/modules/ai/hard-line.ts:219
  var plainText: String {
    switch self {
    case .text(let text): text
    case .parts(let parts): parts.map { $0.text ?? "" }.joined(separator: "\n")
    case .other: ""
    }
  }
}

private func itemTexts(_ item: OrderedJSON) -> [String] {
  guard let record = item.objectValue, let content = record["content"] else { return valueTexts(item) }
  return [HardLineContent(json: content).plainText]
}

// apps/novel-forge-server/src/modules/ai/hard-line.ts:225
func valueTexts(_ value: OrderedJSON) -> [String] {
  switch value {
  case .string(let text): [text]
  case .array(let items): items.flatMap(itemTexts)
  case .object(let record): record.entries.flatMap { valueTexts($0.value) }
  default: []
  }
}

// apps/novel-forge-server/src/modules/ai/hard-line.ts:234
func inputScreens(_ input: OrderedJSONObject) -> [ScreenedText] {
  input.entries.flatMap { entry in
    let key = JSString(entry.key)
    let background = backgroundInputs[key]
    let source = background ?? suppliedInputs[key] ?? "The request"
    return valueTexts(entry.value).map { ScreenedText(text: $0, scope: background == nil ? .supplied : .background, source: source) }
  }
}

// apps/novel-forge-server/src/modules/ai/hard-line.ts:243
func outputScreens(_ output: OrderedJSON, role: String) -> [ScreenedText] {
  let scope = outputScope(role: role)
  return valueTexts(output).map { ScreenedText(text: $0, scope: scope, source: "The generated text") }
}

// apps/novel-forge-server/src/modules/ai/hard-line.ts:249
func wireMessageTexts(_ messages: [WireMessage]) -> [String] {
  messages.map(\.content.plainText)
}

private let suppliedSections: Set<JSString> = ["brief"]

// apps/novel-forge-server/src/modules/ai/hard-line.ts:256
func sectionScreens(_ sections: [ContextSection]) -> [ScreenedText] {
  sections.map { section in
    ScreenedText(
      text: section.rendered,
      scope: suppliedSections.contains(JSString(section.key)) ? .supplied : .background,
      source: describeSection(section.key, sourceRefs: section.sourceRefs),
      sourceRefs: section.sourceRefs
    )
  }
}
