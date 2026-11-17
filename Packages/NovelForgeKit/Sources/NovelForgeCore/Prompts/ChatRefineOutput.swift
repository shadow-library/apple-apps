import Foundation
import ShadowAI

struct ChatLookup: Equatable, Sendable {
  let tool: String
  let args: OrderedJSONObject?
}

struct ChatRefineOutput: ChatTurnOutput, Equatable {
  var reply: String
  var changeSet: [OrderedJSONObject]?
  var lookups: [ChatLookup]?
  var question: OrderedJSON?

  init(reply: String, changeSet: [OrderedJSONObject]? = nil, lookups: [ChatLookup]? = nil, question: OrderedJSON? = nil) {
    self.reply = reply
    self.changeSet = changeSet
    self.lookups = lookups
    self.question = question
  }

  init?(json: OrderedJSON) {
    guard let fields = json.objectValue, let reply = fields["reply"]?.stringValue else { return nil }
    let changeSet = fields["changeSet"]?.arrayValue
    let lookups = fields["lookups"]?.arrayValue
    let lookupFields = lookups?.compactMap(\.objectValue)
    let toolNames = lookupFields?.compactMap { $0["tool"]?.stringValue }
    guard changeSet?.allSatisfy({ $0.objectValue != nil }) ?? true, lookupFields?.count == lookups?.count, toolNames?.count == lookups?.count else { return nil }
    self.init(
      reply: reply, changeSet: changeSet?.compactMap(\.objectValue),
      lookups: lookupFields?.map { ChatLookup(tool: $0["tool"]?.stringValue ?? "", args: $0["args"]?.objectValue) }, question: fields["question"]
    )
  }

  init?(data: Data) {
    guard let json = try? OrderedJSON(parsing: String(decoding: data, as: UTF8.self)) else { return nil }
    self.init(json: json)
  }

  func replacing(reply: String, changeSet: [OrderedJSONObject]?) -> ChatRefineOutput {
    ChatRefineOutput(reply: reply, changeSet: changeSet, lookups: lookups, question: question)
  }
}

private let lookupsUnavailable = "lookups are not available for this scope — answer from the provided context"

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:146
func validateTurnOutput(_ output: OrderedJSON, allowedOps: [OpType]? = nil, lookupsAllowed: Bool = false) -> [String] {
  let fields = output.objectValue
  let lookups = fields?["lookups"]?.arrayValue ?? []
  let changeSet = fields?["changeSet"].flatMap { value -> OrderedJSON? in
    if case .null = value { return nil }
    if case .array(let items) = value, items.isEmpty { return nil }
    return value
  }
  guard !lookups.isEmpty else { return changeSet.map { validateChangeSet($0, allowedOps: allowedOps).errors } ?? [] }
  guard lookupsAllowed else { return [lookupsUnavailable] }
  guard changeSet == nil else { return ["return either lookups or a changeSet, never both in one turn"] }
  return lookups.allSatisfy { !($0.objectValue?["tool"]?.stringValue ?? "").isEmpty } ? [] : ["every lookup needs a tool name"]
}

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:137
func adviseTurnOutput(_ output: OrderedJSON, proseEdits: Bool, organiseNotes: Bool) -> [String] {
  let fields = output.objectValue
  guard (fields?["lookups"]?.arrayValue ?? []).isEmpty else { return [] }
  let changeSet = fields?["changeSet"]?.arrayValue?.map { $0.objectValue ?? OrderedJSONObject([]) }
  return (proseEdits ? [] : proseEditIssues(changeSet)) + laterPlanIssues(changeSet, organiseRequest: organiseNotes)
}

// apps/novel-forge-server/src/modules/ai/prompts/chat-refine.prompt.ts:129
func chatRefineReview(lookupsAllowed: Bool, proseEdits: Bool = false, organiseNotes: Bool = false) -> StructuredReview {
  StructuredReview(
    postValidate: { data in
      guard let json = try? OrderedJSON(parsing: String(decoding: data, as: UTF8.self)) else { return ["the reply is not readable JSON"] }
      return validateTurnOutput(json, allowedOps: hubAllowedOps, lookupsAllowed: lookupsAllowed)
    },
    advise: { data in
      guard let json = try? OrderedJSON(parsing: String(decoding: data, as: UTF8.self)) else { return [] }
      return adviseTurnOutput(json, proseEdits: proseEdits, organiseNotes: organiseNotes)
    }
  )
}
