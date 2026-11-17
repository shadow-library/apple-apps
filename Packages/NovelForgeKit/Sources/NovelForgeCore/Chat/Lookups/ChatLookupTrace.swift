enum ChatTraceStatus: String, Sendable, Equatable {
  case ok
  case error
}

enum ChatTraceValue: Equatable, Sendable {
  case text(String)
  case count(Double)
}

/// The keys of a lookup's arguments that its label reads, in the reference's order; never the lookup's result.
struct ChatTraceArgs: Equatable, Sendable {
  struct Entry: Equatable, Sendable {
    let key: String
    let value: ChatTraceValue
  }

  let entries: [Entry]

  subscript(key: String) -> ChatTraceValue? {
    entries.first { $0.key.jsEquals(key) }?.value
  }
}

// apps/novel-forge-server/src/modules/refinement/chat-turn-trace.ts:11
private let countKeys: Set<String> = ["chapter", "from", "to", "part"]

// apps/novel-forge-server/src/modules/refinement/chat-turn-trace.ts:27
private let traceKeys: [String: [String]] = [
  "get_bible_document": ["slug", "section"],
  "get_brief": ["chapter"],
  "get_draft": ["chapter"],
  "get_review": ["chapter"],
  "get_notes": ["from", "part", "query"],
  "get_chapter_summaries": ["from", "to"],
  "get_plot_threads": ["status"],
  "get_character_timeline": ["entityKey"],
  "get_entity": ["entityKey"],
  "get_volume": ["volumeKey"],
  "get_world_facts": ["category"],
  "search_lore": ["query"],
  "search_prose": ["query"],
  "search_web": ["query"],
  "fetch_page": ["url"],
]

private let queryLimit = 40
private let textLimit = 120

// apps/novel-forge-server/src/modules/refinement/chat-turn-trace.ts:51
private func clipped(_ value: String, limit: Int) -> String {
  value.jsLength > limit ? "\(value.jsSlice(0, limit).jsTrimEnd())…" : value
}

// apps/novel-forge-server/src/modules/refinement/chat-turn-trace.ts:55
private func traceValue(_ key: String, _ value: OrderedJSON?) -> ChatTraceValue? {
  if countKeys.contains(key) {
    guard let number = value?.numberValue, number.isFinite else { return nil }
    return .count(number)
  }
  guard case .string(let text)? = value, !text.jsTrim().isEmpty else { return nil }
  return .text(clipped(text.jsTrim(), limit: key == "query" ? queryLimit : textLimit))
}

// apps/novel-forge-server/src/modules/refinement/chat-turn-trace.ts:61
func traceArgs(tool: String, args: OrderedJSONObject) -> ChatTraceArgs {
  let keys = traceKeys.first { $0.key.jsEquals(tool) }?.value ?? []
  return ChatTraceArgs(entries: keys.compactMap { key in traceValue(key, args[key]).map { ChatTraceArgs.Entry(key: key, value: $0) } })
}
