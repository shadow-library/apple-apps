// apps/novel-forge-server/src/modules/refinement/chat-selection.ts:9
let chatTurnGraph = "chat-turn"

// apps/novel-forge-server/src/modules/ai/defaults.ts:67
let defaultCostTier = CostTier.balanced

struct ChatSelection: Equatable, Sendable {
  var contentMode: ContentMode
  var costTier: CostTier
}

struct ChatSelectionOverride: Equatable, Sendable {
  var contentMode: ContentMode?
  var costTier: CostTier?

  init(contentMode: ContentMode? = nil, costTier: CostTier? = nil) {
    self.contentMode = contentMode
    self.costTier = costTier
  }
}

struct ChatProjectConfig: Equatable, Sendable {
  var contentMode: ContentMode?
  var costTier: CostTier?

  init(contentMode: ContentMode? = nil, costTier: CostTier? = nil) {
    self.contentMode = contentMode
    self.costTier = costTier
  }
}

struct StoredChatSelection: Equatable, Sendable {
  var contentMode: ContentMode?
  var costTier: CostTier?
}

// apps/novel-forge-server/src/modules/refinement/chat-selection.ts:22
func chatSelection(_ turn: ChatSelectionOverride, project: ChatProjectConfig? = nil) -> ChatSelection {
  let projectMode: ContentMode = project?.contentMode == .unrestricted ? .unrestricted : .standard
  return ChatSelection(contentMode: turn.contentMode ?? projectMode, costTier: turn.costTier ?? project?.costTier ?? defaultCostTier)
}

// apps/novel-forge-server/src/modules/refinement/chat-selection.ts:41
func storedChatSelection(costTier: String?, contentMode: String?) -> StoredChatSelection {
  StoredChatSelection(
    contentMode: contentMode.flatMap { text in ContentMode.allCases.first { $0.rawValue.jsEquals(text) } },
    costTier: costTier.flatMap { text in CostTier.allCases.first { $0.rawValue.jsEquals(text) } }
  )
}
