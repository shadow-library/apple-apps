import ShadowCore

public enum DemoReply: Sendable, Equatable {
  case text(String)
  /// Answers a structured call whose schema it satisfies; a text call gets its canonical JSON text.
  case json(JSONValue)
}

/// Which calls a rule answers; every condition that is set must hold.
public struct DemoMatch: Sendable, Equatable {
  public var task: ModelTask?
  /// The structured call's schema name. Set, the rule answers only that structured call; nil, it answers text calls and every structured call.
  public var schema: String?
  /// Found, ignoring case, in the user's last message, read without the structured-output instruction.
  public var phrase: String?

  public init(task: ModelTask? = nil, schema: String? = nil, phrase: String? = nil) {
    self.task = task
    self.schema = schema
    self.phrase = phrase
  }
}

public struct DemoRule: Sendable, Equatable {
  public var match: DemoMatch
  /// Given in turn, one per call the rule answers, starting again after the last; a rule without replies answers nothing.
  public var replies: [DemoReply]

  public init(_ match: DemoMatch, replies: [DemoReply]) {
    self.match = match
    self.replies = replies
  }
}

/// What the demo model answers, supplied by the app: the first rule that matches a call answers it. A text call no rule answers gets `fallback`; a structured
/// call no rule answers, or whose reply does not satisfy its schema, gets the simplest value the schema accepts, with `fallback` in its strings.
public struct DemoScript: Sendable, Equatable {
  public var rules: [DemoRule]
  public var fallback: String

  public init(rules: [DemoRule] = [], fallback: String) {
    self.rules = rules
    self.fallback = fallback
  }
}
