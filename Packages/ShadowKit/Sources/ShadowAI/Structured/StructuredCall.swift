import Foundation
import OSLog
import ShadowCore

public enum StructuredMode: String, Sendable, Codable {
  case native
  case prompt
}

public struct StructuredResult: Sendable, Equatable {
  /// The validated JSON text exactly as the model wrote it, so decimals and large numbers survive.
  public let json: Data
  public let mode: StructuredMode
  /// True when the accepted JSON came from the repair re-ask; otherwise it came from the first reply, the first of `responses`.
  public let wasRepaired: Bool
  public let responses: [ModelResponse]
  /// The ledger ids of the call's requests, through a `RoutedCall`; empty otherwise.
  public let callIDs: [UUID]

  public func decode<T: Decodable>(_ type: T.Type = T.self, decoder: JSONDecoder = JSONDecoder()) throws(StructuredError) -> T {
    do {
      return try decoder.decode(type, from: json)
    } catch {
      throw .decoding(String(describing: error))
    }
  }
}

public enum StructuredError: ShadowError, Equatable {
  case model(ModelError, responses: [ModelResponse])
  case refused(category: String?, responses: [ModelResponse])
  case truncated(responses: [ModelResponse])
  /// Still invalid after the repair re-ask and tolerant extraction; with no responses, the schema itself uses keywords the validator does not implement.
  case invalid(issues: [JSONSchemaIssue], responses: [ModelResponse])
  case decoding(String)

  public var code: String {
    switch self {
    case .model(let error, _): error.code
    case .refused: "structured.refused"
    case .truncated: "structured.truncated"
    case .invalid: "structured.invalid"
    case .decoding: "structured.decoding"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .model(let error, _): error.errorDescription
    case .refused: "The model declined to answer."
    case .truncated: "The model's answer was cut off at its output limit."
    case .invalid(let issues, _): "The model's answer did not have the expected shape (\(issues.count) \(issues.count == 1 ? "problem" : "problems"))."
    case .decoding(let reason): "The model's answer could not be read: \(reason)"
    }
  }
}

public struct StructuredCall: Sendable {
  private enum Verdict {
    case valid(Data)
    case invalid([JSONSchemaIssue])
  }

  private static let contentFilterCategory = "content_filter"
  private static let logger = Logger(category: "ShadowAI.Structured")

  private let provider: any ModelProvider
  private let supportsNativeSchema: Bool
  private let providerName: String

  public init(provider: any ModelProvider, supportsNativeSchema: Bool) {
    self.init(provider: provider, supportsNativeSchema: supportsNativeSchema, providerName: String(describing: type(of: provider)))
  }

  init(provider: any ModelProvider, supportsNativeSchema: Bool, providerName: String) {
    self.provider = provider
    self.supportsNativeSchema = supportsNativeSchema
    self.providerName = providerName
  }

  /// `stream` without an observer.
  public func run(_ request: ModelRequest, name: String, schema: JSONValue, review: StructuredReview = .none) async throws(StructuredError) -> StructuredResult {
    do throws(StructuredStreamFailure) {
      return try await stream(request, name: name, schema: schema, review: review)
    } catch {
      throw error.error
    }
  }

  /// Makes at most two model calls in a mode, the request and one repair re-ask, and checks every reply against the full schema, also in native mode.
  /// Native mode first when the provider takes the schema; a native request refused with `noEligibleModel` before any text is sent again in the prompt form.
  public func stream(
    _ request: ModelRequest, name: String, schema: JSONValue, review: StructuredReview = .none, observer: (StructuredStreamEvent) -> Void = { _ in }
  ) async throws(StructuredStreamFailure) -> StructuredResult {
    try await stream(request, name: name, schema: schema, review: review, observer: observer, callIDs: { [] })
  }

  func stream(
    _ request: ModelRequest, name: String, schema: JSONValue, review: StructuredReview, observer: (StructuredStreamEvent) -> Void, callIDs: () async -> [UUID]
  ) async throws(StructuredStreamFailure) -> StructuredResult {
    var attempts = StructuredAttempts(provider: provider)
    do throws(StructuredError) {
      let accepted = try await answer(request, name: name, schema: schema, review: review, attempts: &attempts, observer: observer)
      let result = StructuredResult(
        json: accepted.json, mode: accepted.mode, wasRepaired: accepted.wasRepaired, responses: accepted.responses, callIDs: await callIDs())
      observer(.completed(.succeeded(result)))
      return result
    } catch {
      let failure = StructuredStreamFailure(error: error, partialText: attempts.partialText, callIDs: await callIDs())
      observer(.completed(.failed(failure)))
      throw failure
    }
  }

  private func answer(
    _ request: ModelRequest, name: String, schema: JSONValue, review: StructuredReview, attempts: inout StructuredAttempts, observer: (StructuredStreamEvent) -> Void
  ) async throws(StructuredError) -> StructuredResult {
    let unsupported = StructuredSchema.unsupportedKeywords(schema)
    guard unsupported.isEmpty else { throw .invalid(issues: unsupported, responses: []) }
    guard supportsNativeSchema, let nativeSchema = StructuredSchema.nativeForm(of: schema) else {
      return try await ladder(request, nativeSchema: nil, name: name, schema: schema, review: review, attempts: &attempts, observer: observer)
    }
    do throws(StructuredError) {
      return try await ladder(request, nativeSchema: nativeSchema, name: name, schema: schema, review: review, attempts: &attempts, observer: observer)
    } catch {
      guard case .model(.noEligibleModel, let responses) = error, responses.isEmpty, attempts.partialText.isEmpty else { throw error }
      Self.logger.notice(
        "Native schema mode found no eligible model; retrying in the prompt form provider=\(providerName, privacy: .public) model=\(request.model, privacy: .public)")
      return try await ladder(request, nativeSchema: nil, name: name, schema: schema, review: review, attempts: &attempts, observer: observer)
    }
  }

  /// The reference's repair ladder (novel-forge-server/src/modules/ai/model-router.service.ts:527-605): the first reply is judged by the schema, then
  /// `postValidate` and `advise`; one repair re-ask carries every issue; the repair is judged without `advise`; tolerant extraction tries the repair's
  /// other values, then the first reply's, which keeps a first reply that had only advisory issues.
  private func ladder(
    _ request: ModelRequest, nativeSchema: JSONValue?, name: String, schema: JSONValue, review: StructuredReview, attempts: inout StructuredAttempts,
    observer: (StructuredStreamEvent) -> Void
  ) async throws(StructuredError) -> StructuredResult {
    let mode: StructuredMode = nativeSchema == nil ? .prompt : .native
    if mode == .prompt, request.messages.last?.role != .user {
      throw .model(.invalidRequest("The schema instruction goes on the last message, which must come from the user."), responses: attempts.responses)
    }
    let initial = Self.prepare(request, nativeSchema: nativeSchema, name: name, schema: schema)

    let first = try await attempts.make(initial, mode: mode, purpose: .answer, observer: observer)
    let firstAttempt = attempts.count
    try Self.requireAnswer(first, responses: attempts.responses)
    let firstBytes = Array(first.text.utf8)
    let firstCandidates = StructuredExtraction.candidates(in: firstBytes)
    let firstIssues: [JSONSchemaIssue]
    let isFirstUsable: Bool
    switch Self.schemaVerdict(firstCandidates.first, in: firstBytes, schema: schema) {
    case .invalid(let issues):
      firstIssues = issues
      isFirstUsable = false
    case .valid(let json):
      let judgement = review.judge(json, true)
      guard !judgement.blocking.isEmpty || !judgement.advisory.isEmpty else {
        attempts.accept(attempt: firstAttempt, observer: observer)
        return StructuredResult(json: json, mode: mode, wasRepaired: false, responses: attempts.responses, callIDs: [])
      }
      firstIssues = judgement.blocking + judgement.advisory
      isFirstUsable = judgement.blocking.isEmpty
    }

    var repair = initial
    if !first.text.allSatisfy(\.isWhitespace) { repair.messages.append(.assistant(first.text)) }
    repair.messages.append(.user(StructuredPrompt.repairRequest(issues: firstIssues, previousOutput: first.text, schema: schema)))
    let second = try await attempts.make(repair, mode: mode, purpose: .repair(issues: firstIssues), observer: observer)
    let secondAttempt = attempts.count
    if !isFirstUsable { try Self.requireAnswer(second, responses: attempts.responses) }
    let secondBytes = Array(second.text.utf8)
    let secondCandidates = StructuredExtraction.candidates(in: secondBytes)
    let secondIssues: [JSONSchemaIssue]
    switch Self.verdict(secondCandidates.first, in: secondBytes, schema: schema, review: review) {
    case .valid(let json):
      attempts.accept(attempt: secondAttempt, observer: observer)
      return StructuredResult(json: json, mode: mode, wasRepaired: true, responses: attempts.responses, callIDs: [])
    case .invalid(let issues): secondIssues = issues
    }

    for candidate in secondCandidates.dropFirst() {
      guard case .valid(let json) = Self.verdict(candidate, in: secondBytes, schema: schema, review: review) else { continue }
      attempts.accept(attempt: secondAttempt, observer: observer)
      return StructuredResult(json: json, mode: mode, wasRepaired: true, responses: attempts.responses, callIDs: [])
    }
    for candidate in firstCandidates.dropFirst(isFirstUsable ? 0 : 1) {
      guard case .valid(let json) = Self.verdict(candidate, in: firstBytes, schema: schema, review: review) else { continue }
      attempts.accept(attempt: firstAttempt, observer: observer)
      return StructuredResult(json: json, mode: mode, wasRepaired: false, responses: attempts.responses, callIDs: [])
    }
    throw .invalid(issues: secondIssues, responses: attempts.responses)
  }

  /// A reply whose stop says it is no answer fails the call, except a repair after a first reply kept for advisory issues only, which the reference
  /// reads as text like any other (model-router.service.ts:548-600).
  private static func requireAnswer(_ response: ModelResponse, responses: [ModelResponse]) throws(StructuredError) {
    switch response.stop {
    case .refusal(let category): throw .refused(category: category, responses: responses)
    case .contentFilter: throw .refused(category: contentFilterCategory, responses: responses)
    case .maxTokens: throw .truncated(responses: responses)
    case .endTurn, .other: return
    }
  }

  /// The system segments are left untouched, so the stable prefix and its cache breakpoint stay byte-identical.
  private static func prepare(_ request: ModelRequest, nativeSchema: JSONValue?, name: String, schema: JSONValue) -> ModelRequest {
    var prepared = request
    if let nativeSchema {
      prepared.format = .json(name: name, schema: nativeSchema)
      return prepared
    }
    prepared.format = .text
    if let last = prepared.messages.indices.last {
      prepared.messages[last].text += "\n\n" + StructuredPrompt.schemaInstruction(name: name, schema: schema)
    }
    return prepared
  }

  private static func verdict(_ candidate: StructuredJSONValue?, in bytes: [UInt8], schema: JSONValue, review: StructuredReview) -> Verdict {
    switch schemaVerdict(candidate, in: bytes, schema: schema) {
    case .invalid(let issues): return .invalid(issues)
    case .valid(let json):
      let blocking = review.judge(json, false).blocking
      return blocking.isEmpty ? .valid(json) : .invalid(blocking)
    }
  }

  private static func schemaVerdict(_ candidate: StructuredJSONValue?, in bytes: [UInt8], schema: JSONValue) -> Verdict {
    guard let candidate else { return .invalid([missingJSONIssue(in: bytes)]) }
    let value = unwrapped(candidate, schema: schema)
    let issues = StructuredSchema.validate(value, against: schema)
    return issues.isEmpty ? .valid(Data(bytes[value.range])) : .invalid(issues)
  }

  /// A model asked for a top-level array often wraps it as `{ "<key>": [...] }`; only that exact shape is unwrapped.
  private static func unwrapped(_ value: StructuredJSONValue, schema: JSONValue) -> StructuredJSONValue {
    guard StructuredSchema.rootType(of: schema) == "array", case .object(let members) = value.node else { return value }
    let arrays = members.filter {
      guard case .array = $0.value.node else { return false }
      return true
    }
    guard arrays.count == 1, let only = arrays.first else { return value }
    return only.value
  }

  private static func missingJSONIssue(in bytes: [UInt8]) -> JSONSchemaIssue {
    guard let start = bytes.firstIndex(where: { !StructuredJSONParser.isWhitespace($0) }) else {
      return JSONSchemaIssue(path: "$", message: "is missing: the response is empty")
    }
    guard bytes[start] == UInt8(ascii: "{") || bytes[start] == UInt8(ascii: "[") else {
      return JSONSchemaIssue(path: "$", message: "is missing: no JSON value was found in the response")
    }
    do {
      _ = try StructuredJSONParser.parse(bytes, in: start..<bytes.count)
      return JSONSchemaIssue(path: "$", message: "is missing: no JSON value was found in the response")
    } catch {
      return StructuredSchema.syntaxIssue(error)
    }
  }
}
