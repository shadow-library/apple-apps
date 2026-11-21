import ShadowText

/// A suggestion as the model wrote it: any object or array `parseDraft` keeps, read with JavaScript's property access and coercions.
public struct DraftSuggestion: Sendable, Equatable {
  public let raw: OrderedJSON

  public init(_ raw: OrderedJSON) {
    self.raw = raw
  }

  public var kind: OrderedJSON? { member("kind") }
  public var questID: OrderedJSON? { member("questId") }
  public var text: OrderedJSON? { member("text") }

  /// `suggestion.text ?? ''`, as the guardrails read it.
  var textOrEmpty: String {
    guard let text, text != .null else { return "" }
    return JSCoercion.string(text)
  }

  private func member(_ name: String) -> OrderedJSON? {
    guard case .object(let object) = raw else { return nil }
    return object[name]
  }
}

/// The prompt contract's response shape before the guardrails have seen it.
public struct InsightDraft: Sendable, Equatable {
  public var answer: String
  public var patterns: [String]
  public var suggestions: [DraftSuggestion]
  public var limitationNote: String?

  public init(answer: String, patterns: [String] = [], suggestions: [DraftSuggestion] = [], limitationNote: String? = nil) {
    self.answer = answer
    self.patterns = patterns
    self.suggestions = suggestions
    self.limitationNote = limitationNote
  }

  /// `parseDraft`: only `answer` is required; other members of the wrong type are dropped, never repaired.
  // apps/memoir-server/src/modules/ai-worker/prompt-contract.ts:33-44
  public init(parsing raw: OrderedJSON) throws(InsightError) {
    guard case .object(let draft) = raw, case .string(let answer)? = draft["answer"] else { throw .unusableAnswer }
    let patterns = draft["patterns"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let suggestions = draft["suggestions"]?.arrayValue?.filter(\.isJSObject).map(DraftSuggestion.init) ?? []
    self.init(answer: answer, patterns: patterns, suggestions: suggestions, limitationNote: draft["limitationNote"]?.stringValue)
  }

  public var json: OrderedJSON {
    .object(
      OrderedJSONObject([
        (key: "answer", value: .string(answer)), (key: "patterns", value: .array(patterns.map(OrderedJSON.string))),
        (key: "suggestions", value: .array(suggestions.map(\.raw))), (key: "limitationNote", value: limitationNote.map(OrderedJSON.string) ?? .null),
      ]))
  }

  /// `draftText`: every text the owner would read, one per line.
  // apps/memoir-server/src/modules/ai-worker/guardrails.ts:111-113
  var text: String {
    ([answer] + patterns + suggestions.map(\.textOrEmpty) + [limitationNote ?? ""]).joined(separator: "\n")
  }
}

extension OrderedJSON {
  var isJSObject: Bool {
    switch self {
    case .object, .array: true
    case .null, .bool, .int, .double, .string: false
    }
  }
}

/// ECMAScript `ToString` of a parsed JSON value, as `String(value)` and `Array.prototype.join` apply it.
enum JSCoercion {
  static func string(_ value: OrderedJSON) -> String {
    switch value {
    case .null: "null"
    case .bool(let flag): flag ? "true" : "false"
    case .int(let number): Double(number).jsString
    case .double(let number): number.jsString
    case .string(let text): text
    case .array(let items): items.map { $0 == .null ? "" : string($0) }.joined(separator: ",")
    case .object: "[object Object]"
    }
  }
}
