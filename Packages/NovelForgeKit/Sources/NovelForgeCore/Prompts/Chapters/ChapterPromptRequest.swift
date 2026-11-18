import ShadowAI

struct ChapterPromptRequest: Equatable, Sendable {
  // apps/novel-forge-server/src/modules/ai/prompt-caching.ts:6
  static let minCacheableTokens = 1024
  static let maxBreakpoints = 4

  enum Layout: Equatable, Sendable {
    case stablePrefix
    case conversation(format: ResponseFormat)
  }

  let messages: [PromptMessage]
  let cacheBreakpoints: [Int]
  let layout: Layout

  // apps/novel-forge-server/src/modules/ai/prompt-caching.ts:45
  init(_ messages: [PromptMessage], layout: Layout, skippingUsers skipped: Int = 0) {
    let users = messages.indices.filter { messages[$0].role == .user }
    let stable = users.dropFirst(skipped).prefix(1)
    let systemIndex = messages.firstIndex { $0.role == .system } ?? -1
    self.init(messages, layout: layout, breakpointsAt: [systemIndex] + stable + [messages.count - 2])
  }

  // apps/novel-forge-server/src/modules/ai/prompt-caching.ts:32
  // countTokens is the deterministic estimate (decision 18), so a prefix near the threshold may be marked here and not in the reference.
  init(_ messages: [PromptMessage], layout: Layout, breakpointsAt indexes: [Int]) {
    self.messages = messages
    self.layout = layout
    var prefixTokens = 0
    guard
      let firstCacheable = messages.firstIndex(where: { message in
        prefixTokens += countTokens(message.text)
        return prefixTokens >= Self.minCacheableTokens
      })
    else {
      cacheBreakpoints = []
      return
    }
    let eligible = Set(indexes).filter { $0 >= firstCacheable && $0 < messages.count }.sorted()
    cacheBreakpoints = Array(eligible.suffix(Self.maxBreakpoints))
  }

  // The Anthropic adapter caches through the last message, OpenRouter at the message before it, so the conversation layouts cache the context message on OpenRouter only.
  func modelRequest(model: String, maxOutputTokens: Int, effort: Effort? = nil) -> ModelRequest {
    switch layout {
    case .stablePrefix:
      ModelRequest(
        model: model, system: [ContextSegment(text: messages[0].text), ContextSegment(text: messages[1].text, endsStablePrefix: true)],
        messages: messages.dropFirst(2).map { .user($0.text) }, maxOutputTokens: maxOutputTokens, effort: effort)
    case .conversation(let format):
      ModelRequest(
        model: model, system: messages.filter { $0.role == .system }.map { ContextSegment(text: $0.text) },
        messages: messages.filter { $0.role != .system }.map { $0.role == .assistant ? .assistant($0.text) : .user($0.text) }, maxOutputTokens: maxOutputTokens,
        effort: effort, format: format, cachesConversation: true)
    }
  }
}
