public struct ChatQuestionAnswer: Equatable, Sendable {
  public internal(set) var title: String
  public internal(set) var why: String?
  public internal(set) var tradeOff: String?
  public internal(set) var recommended: Bool
}

public struct ChatQuestion: Equatable, Sendable {
  public internal(set) var question: String
  public internal(set) var why: String?
  public internal(set) var answers: [ChatQuestionAnswer]
  public internal(set) var progressKey: String?
}

// apps/novel-forge-server/src/modules/refinement/chat-question.ts:19
private let minAnswers = 2
// apps/novel-forge-server/src/modules/refinement/chat-question.ts:20
private let maxAnswers = 4
// apps/novel-forge-server/src/modules/refinement/chat-question.ts:21
private let historyQuestionChars = 160
// apps/novel-forge-server/src/modules/refinement/chat-question.ts:22
private let historyTitleChars = 60

private func entry(_ key: String, _ value: OrderedJSON) -> (key: String, value: OrderedJSON) { (key: key, value: value) }

private func object(_ pairs: [(key: String, value: OrderedJSON)]) -> OrderedJSON { .object(OrderedJSONObject(pairs)) }

private func nonBlankText() -> OrderedJSON { object([entry("type", .string("string")), entry("minLength", .int(1))]) }

// apps/novel-forge-server/src/modules/refinement/chat-question.ts:27
let chatQuestionWireSchema: OrderedJSON = object([
  entry("type", .string("object")),
  entry(
    "properties",
    object([
      entry("question", nonBlankText()),
      entry("why", object([entry("type", .string("string"))])),
      entry(
        "answers",
        object([
          entry("type", .string("array")),
          entry("minItems", .int(Int64(minAnswers))),
          entry("maxItems", .int(Int64(maxAnswers))),
          entry(
            "items",
            object([
              entry("type", .string("object")),
              entry(
                "properties",
                object([
                  entry("title", nonBlankText()),
                  entry("why", object([entry("type", .string("string"))])),
                  entry("tradeOff", object([entry("type", .string("string"))])),
                  entry("recommended", object([entry("type", .string("boolean"))])),
                ])),
              entry("required", .array([.string("title")])),
              entry("additionalProperties", .bool(false)),
            ])),
        ])),
      entry("progressKey", object([entry("type", .string("string")), entry("enum", .array(progressItemKeys.map { .string($0.rawValue) }))])),
    ])),
  entry("required", .array([.string("question"), .string("answers")])),
  entry("additionalProperties", .bool(false)),
])

private func isTrue(_ value: OrderedJSON?) -> Bool {
  guard case .bool(true)? = value else { return false }
  return true
}

private func nonBlankString(_ value: OrderedJSON?) -> String? {
  guard let text = value?.stringValue, !text.jsTrim().isEmpty else { return nil }
  return text
}

// apps/novel-forge-server/src/modules/refinement/chat-question.ts:54
func sanitizeChatQuestion(_ candidate: OrderedJSON?, allowedProgressKeys: [String]) -> ChatQuestion? {
  guard let raw = candidate?.objectValue, let question = nonBlankString(raw["question"]) else { return nil }
  guard let items = raw["answers"]?.arrayValue, items.count >= minAnswers, items.count <= maxAnswers else { return nil }
  var answers: [ChatQuestionAnswer] = []
  for item in items {
    guard let fields = item.objectValue, let title = nonBlankString(fields["title"]) else { return nil }
    answers.append(ChatQuestionAnswer(title: title, why: fields["why"]?.stringValue, tradeOff: fields["tradeOff"]?.stringValue, recommended: isTrue(fields["recommended"])))
  }
  let key = raw["progressKey"]?.stringValue.flatMap { key in allowedProgressKeys.contains { $0.jsEquals(key) } && !key.isEmpty ? key : nil }
  return ChatQuestion(question: question, why: raw["why"]?.stringValue, answers: answers, progressKey: key)
}

extension ChatQuestion {
  var json: OrderedJSON {
    var pairs = [entry("question", .string(question))]
    if let why { pairs.append(entry("why", .string(why))) }
    pairs.append(entry("answers", .array(answers.map(\.json))))
    if let progressKey { pairs.append(entry("progressKey", .string(progressKey))) }
    return object(pairs)
  }
}

extension ChatQuestionAnswer {
  var json: OrderedJSON {
    var pairs = [entry("title", .string(title))]
    if let why { pairs.append(entry("why", .string(why))) }
    if let tradeOff { pairs.append(entry("tradeOff", .string(tradeOff))) }
    if recommended { pairs.append(entry("recommended", .bool(true))) }
    return object(pairs)
  }
}

// apps/novel-forge-server/src/modules/refinement/chat-question.ts:79
func renderQuestionForHistory(_ question: OrderedJSON?) -> String? {
  guard let raw = question?.objectValue, let text = nonBlankString(raw["question"]) else { return nil }
  let titles = (raw["answers"]?.arrayValue ?? []).compactMap { answer in
    nonBlankString(answer.objectValue?["title"]).map { clipAtBoundary($0, maxChars: historyTitleChars) }
  }
  let asked = clipAtBoundary(text, maxChars: historyQuestionChars)
  return titles.isEmpty ? "[Asked: \(asked)]" : "[Asked: \(asked) — options: \(titles.joined(separator: " / "))]"
}
