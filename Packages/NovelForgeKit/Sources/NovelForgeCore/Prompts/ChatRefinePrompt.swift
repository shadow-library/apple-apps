import ShadowAI

let chatRefineVersion = "2.24.1"

let chatRefineStableMessages = 2

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:20
let chatRefineSystem = "\(authoringStylePlanning)\n\n\(editByDeletion)\n\n\(chatRefineSystemBody)"

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:50
private let chatTemplateOverhead = 64

struct ChatLookupTool: Equatable, Sendable {
  let name: String
  let arguments: [String]?
  let description: String
}

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:61
func chatScopeInstructions(_ tools: [ChatLookupTool]) -> String {
  let lines = tools.map { "- \($0.name) (args: \($0.arguments.map { $0.joined(separator: ", ") } ?? "see description")) — \($0.description)" }
  return "\(hubInstructions)\n\nLookup tools available this scope (read-only):\n\(lines.joined(separator: "\n"))"
}

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:71
func chatPromptTokens(_ scopeInstructions: String) -> Int {
  countTokens(chatRefineSystem) + countTokens(scopeInstructions) + chatTemplateOverhead
}

struct TurnMessageParts: Equatable, Sendable {
  var volatileContext: String
  var turnRules: String
  var userMessage: String
}

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:31
func renderTurnMessage(_ parts: TurnMessageParts) -> String {
  "Where the story stands now:\n\(parts.volatileContext)\n\n\(parts.turnRules)\n\n\(parts.userMessage)"
}

struct ChatRefineRequestParts: Equatable, Sendable {
  let system: [ContextSegment]
  let conversation: [PromptMessage]

  init(scopeInstructions: String, stableContext: String, history: [PromptMessage] = [], turn: TurnMessageParts, rounds: [PromptMessage] = []) {
    system = [
      ContextSegment(text: chatRefineSystem), ContextSegment(text: "Scope playbook:\n\(scopeInstructions)"),
      ContextSegment(text: stableContext, endsStablePrefix: true),
    ]
    conversation = history + [PromptMessage(.user, renderTurnMessage(turn))] + rounds
  }
}

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:38
func chatRefineMessages(
  scopeInstructions: String, stableContext: String, history: [PromptMessage] = [], turn: TurnMessageParts, rounds: [PromptMessage] = []
) -> [PromptMessage] {
  let parts = ChatRefineRequestParts(scopeInstructions: scopeInstructions, stableContext: stableContext, history: history, turn: turn, rounds: rounds)
  let framing = parts.system.enumerated().map { PromptMessage($0.offset == 0 ? .system : .user, $0.element.text) }
  return framing + parts.conversation
}

struct ChatTurnPermissions: Equatable, Sendable {
  var proseEdits: Bool
  var justDiscussing: Bool
  var organiseNotes: Bool
  var mode: RefinementChatMode

  init(proseEdits: Bool, justDiscussing: Bool = false, organiseNotes: Bool = false, mode: RefinementChatMode) {
    self.proseEdits = proseEdits
    self.justDiscussing = justDiscussing
    self.organiseNotes = organiseNotes
    self.mode = mode
  }
}

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:103
private let justDiscussingRule =
  "Just discussing: ON — the author is thinking aloud, so nothing this turn applies. Any change you propose becomes a suggestion card for the author to accept or decline; leave quotes out."

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:107
private let autoWriteRule =
  "Write policy: Edit freely — your own ideas (no quote) are added to the Story Bible immediately along with the author's quoted words, and the author can undo any of them. Propose an invention with the care you would take writing canon, and describe it as added; the server tells the author if anything waited instead. A turn that looked up the author's notes or a planner-only page applies only milestones, which only planning reads — every other change, the premise, story brief and themes included, waits as a card, so describe those as suggested. These always come to the author as cards to accept, never applied: removals and cleared fields, replacing a filled story field, plans, prose, actions, a secret's truth or gating, planner-only pages and volume goals, a volume's order and structure, a promise's status, payoff or progress or reusing a settled promise, and an idea that would remove more than a quarter of a filled field's text."

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:109
private let manualWriteRule =
  "Write policy: Ask first — nothing applies until the author accepts it. Every op, quoted or your own idea, is a suggestion card, so propose your ideas boldly, without a quote."

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:112
private let organiseStartsRule =
  "Organising the notes: the author asked for it, so it starts by itself at the end of this turn, with no card to accept. Never describe it as a card or ask the author to accept it; the server adds a line saying it started, or why it waits."

private let proseOnRule =
  "Prose edits: ON — the author turned on Edit prose, so draft.rewrite_passage, draft.update, draft.remove and action.revise_draft are available this turn; answer a passage comment with draft.rewrite_passage."

private let proseOffRule =
  "Prose edits: OFF — the author did not turn on Edit prose. draft.rewrite_passage, draft.update, draft.remove and action.revise_draft will be rejected, along with approving, judging or finalizing that prose; keep a plan edit in the plan."

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:115
func renderTurnRules(_ permissions: ChatTurnPermissions) -> String {
  let writes = permissions.justDiscussing ? justDiscussingRule : (permissions.mode == .auto ? autoWriteRule : manualWriteRule)
  let organise = organiseRouting(organiseRequest: permissions.organiseNotes, mode: permissions.mode, justDiscussing: permissions.justDiscussing)
  return ([permissions.proseEdits ? proseOnRule : proseOffRule, writes] + (organise == .start ? [organiseStartsRule] : [])).joined(separator: "\n")
}
