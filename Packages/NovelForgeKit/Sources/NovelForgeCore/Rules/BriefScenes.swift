import ShadowText

public struct BriefScene: Equatable, Sendable, Codable {
  public var summary: String
  public var pov: String?
  public var goal: String?
  public var obstacle: String?
  public var turn: String?
  public var beats: [String]?
  public var estimatedWords: Int?

  public init(summary: String, pov: String? = nil, goal: String? = nil, obstacle: String? = nil, turn: String? = nil, beats: [String]? = nil, estimatedWords: Int? = nil) {
    self.summary = summary
    self.pov = pov
    self.goal = goal
    self.obstacle = obstacle
    self.turn = turn
    self.beats = beats
    self.estimatedWords = estimatedWords
  }

  private enum CodingKeys: String, CodingKey {
    case summary, pov, goal, obstacle, turn, beats, estimatedWords
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    summary = try container.decode(String.self, forKey: .summary)
    pov = try container.decodeIfPresent(String.self, forKey: .pov)
    goal = try container.decodeIfPresent(String.self, forKey: .goal)
    obstacle = try container.decodeIfPresent(String.self, forKey: .obstacle)
    turn = try container.decodeIfPresent(String.self, forKey: .turn)
    beats = try container.decodeIfPresent([String].self, forKey: .beats)
    estimatedWords = try container.decodeIfPresent(Int.self, forKey: .estimatedWords)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(summary, forKey: .summary)
    try container.encode(pov, forKey: .pov)
    try container.encodeIfPresent(goal, forKey: .goal)
    try container.encodeIfPresent(obstacle, forKey: .obstacle)
    try container.encodeIfPresent(turn, forKey: .turn)
    try container.encodeIfPresent(beats, forKey: .beats)
    try container.encodeIfPresent(estimatedWords, forKey: .estimatedWords)
  }
}

private let sceneTextFields = ["goal", "obstacle", "turn"]
private let sceneFields = ["summary", "pov"] + sceneTextFields + ["beats", "estimatedWords"]

private func isString(_ value: OrderedJSON) -> Bool {
  if case .string = value { return true }
  return false
}

private func isStringList(_ value: OrderedJSON) -> Bool {
  guard case .array(let items) = value else { return false }
  return items.allSatisfy(isString)
}

private func isNonBlankString(_ value: OrderedJSON?) -> Bool {
  guard case .string(let text)? = value else { return false }
  return !text.jsTrim().isEmpty
}

private func isPositiveInteger(_ value: OrderedJSON) -> Bool {
  guard let number = value.numberValue else { return false }
  return number.jsIsInteger && number >= 1
}

private func detailErrors(_ record: OrderedJSONObject, at: String) -> [String] {
  var errors = sceneTextFields.compactMap { field -> String? in
    guard let value = record[field], !isString(value) else { return nil }
    return "\(at).\(field) must be a string"
  }
  if let beats = record["beats"], !isStringList(beats) { errors.append("\(at).beats must be a list of strings") }
  return errors + wordsErrors(record, at: at)
}

private func wordsErrors(_ record: OrderedJSONObject, at: String) -> [String] {
  guard let words = record["estimatedWords"], !isPositiveInteger(words) else { return [] }
  return ["\(at).estimatedWords must be an integer >= 1"]
}

// apps/novel-forge-server/src/common/brief-scenes.ts:15
func validateBriefScenes(_ value: OrderedJSON) -> [String] {
  guard case .array(let scenes) = value else { return ["scenes must be an array"] }
  return scenes.enumerated().flatMap { index, scene -> [String] in
    let at = "scenes[\(index)]"
    guard case .object(let record) = scene else { return ["\(at) must be an object"] }
    var errors = record.keys.filter { key in !sceneFields.contains { $0.jsEquals(key) } }.map { "\(at) has unexpected field '\($0)'" }
    if !isNonBlankString(record["summary"]) { errors.append("\(at).summary must be a non-empty string") }
    if let pov = record["pov"], pov != .null, !isNonBlankString(pov) { errors.append("\(at).pov must be an entity key or null") }
    return errors + detailErrors(record, at: at)
  }
}

// apps/novel-forge-server/src/common/brief-scenes.ts:32
func normalizeStringList(_ values: [String]) -> [String] {
  values.map { $0.jsTrim() }.filter { !$0.isEmpty }.jsUnique()
}

private func nonBlank(_ text: String?) -> String? {
  guard let trimmed = text?.jsTrim(), !trimmed.isEmpty else { return nil }
  return trimmed
}

// apps/novel-forge-server/src/common/brief-scenes.ts:39
func normalizeBriefScenes(_ scenes: [BriefScene]) -> [BriefScene] {
  scenes.map { scene in
    let beats = scene.beats?.map { $0.jsTrim() }.filter { !$0.isEmpty }
    return BriefScene(
      summary: scene.summary.jsTrim(),
      pov: nonBlank(scene.pov),
      goal: nonBlank(scene.goal),
      obstacle: nonBlank(scene.obstacle),
      turn: nonBlank(scene.turn),
      beats: beats?.isEmpty == false ? beats : nil,
      estimatedWords: scene.estimatedWords == 0 ? nil : scene.estimatedWords
    )
  }
}
