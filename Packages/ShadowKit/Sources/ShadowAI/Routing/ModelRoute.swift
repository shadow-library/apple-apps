public enum ModelContentMode: String, Sendable, Codable, CaseIterable {
  case standard
  case unrestricted
}

public enum ModelProviderKind: String, Sendable, Codable, CaseIterable {
  case anthropic
  case openRouter = "openrouter"
}

public struct AIConsentRequirement: Sendable, Equatable {
  public var dataClass: String
  /// A stable identifier of what is sent, such as `novel-text/v1`, never the sheet's localised wording: consent syncs, so devices in other languages
  /// must read the same value. Changing what is sent means a new identifier, which asks again.
  public var disclosure: String

  public init(dataClass: String, disclosure: String) {
    self.dataClass = dataClass
    self.disclosure = disclosure
  }
}

public struct TaskCall: Sendable, Equatable {
  public var task: ModelTask
  public var pace: Pace
  public var thinksDeeper: Bool
  public var contentMode: ModelContentMode
  public var consent: AIConsentRequirement

  public init(task: ModelTask, pace: Pace, thinksDeeper: Bool = false, contentMode: ModelContentMode = .standard, consent: AIConsentRequirement) {
    self.task = task
    self.pace = pace
    self.thinksDeeper = thinksDeeper
    self.contentMode = contentMode
    self.consent = consent
  }
}

public struct ModelRoute: Sendable, Equatable {
  public let task: ModelTask
  public let pace: Pace
  public let thinksDeeper: Bool
  /// Whether Think deeper changed the route; false where it has nothing to raise, so the option can be hidden.
  public let deepened: Bool
  public let contentMode: ModelContentMode
  public let provider: ModelProviderKind
  public let model: String
  public let effort: Effort?
  public let maxOutputTokens: Int
  public let supportsNativeSchema: Bool

  public init(
    task: ModelTask, pace: Pace, thinksDeeper: Bool, deepened: Bool, contentMode: ModelContentMode, provider: ModelProviderKind, model: String, effort: Effort?,
    maxOutputTokens: Int, supportsNativeSchema: Bool
  ) {
    self.task = task
    self.pace = pace
    self.thinksDeeper = thinksDeeper
    self.deepened = deepened
    self.contentMode = contentMode
    self.provider = provider
    self.model = model
    self.effort = effort
    self.maxOutputTokens = maxOutputTokens
    self.supportsNativeSchema = supportsNativeSchema
  }
}
