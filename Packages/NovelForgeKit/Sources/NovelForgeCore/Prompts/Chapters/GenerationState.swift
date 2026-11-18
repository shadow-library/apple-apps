// apps/novel-forge-server/src/modules/ai/schemas/generation.schema.ts:4
struct CharacterPosition: Codable, Equatable, Sendable {
  var entityKey: String
  var location: String
}

// apps/novel-forge-server/src/modules/ai/schemas/generation.schema.ts:13
struct GenerationState: Codable, Equatable, Sendable {
  var openConflict: String?
  var characterPositions: [CharacterPosition]?
  var lastBeat: String?
  var emotionalState: String?
  var establishedFacts: [String]?

  init(
    openConflict: String? = nil, characterPositions: [CharacterPosition]? = nil, lastBeat: String? = nil, emotionalState: String? = nil,
    establishedFacts: [String]? = nil
  ) {
    self.openConflict = openConflict
    self.characterPositions = characterPositions
    self.lastBeat = lastBeat
    self.emotionalState = emotionalState
    self.establishedFacts = establishedFacts
  }
}

// apps/novel-forge-server/src/modules/ai/schemas/generation.schema.ts:37
struct ChapterDraftOutput: Codable, Equatable, Sendable {
  var title: String
  var body: String
  var summary: String
  var state: GenerationState?
}
