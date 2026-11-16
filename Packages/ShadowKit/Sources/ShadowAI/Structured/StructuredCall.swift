import Foundation
import ShadowCore

public enum StructuredMode: String, Sendable, Codable {
  case native
  case prompt
}

public struct StructuredResult: Sendable {
  /// The validated JSON text exactly as the model wrote it, so decimals and large numbers survive.
  public let json: Data
  public let mode: StructuredMode
  /// True when the accepted JSON came from the repair re-ask.
  public let wasRepaired: Bool
  public let responses: [ModelResponse]

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

  private let provider: any ModelProvider
  private let supportsNativeSchema: Bool

  public init(provider: any ModelProvider, supportsNativeSchema: Bool) {
    self.provider = provider
    self.supportsNativeSchema = supportsNativeSchema
  }

  /// Makes at most two model calls, the request and one repair re-ask, and checks every reply against the full schema, also in native mode.
  public func run(_ request: ModelRequest, name: String, schema: JSONValue) async throws(StructuredError) -> StructuredResult {
    let unsupported = StructuredSchema.unsupportedKeywords(schema)
    guard unsupported.isEmpty else { throw .invalid(issues: unsupported, responses: []) }
    let nativeSchema = supportsNativeSchema ? StructuredSchema.nativeForm(of: schema) : nil
    let mode: StructuredMode = nativeSchema == nil ? .prompt : .native
    if mode == .prompt, request.messages.last?.role != .user {
      throw .model(.invalidRequest("The schema instruction goes on the last message, which must come from the user."), responses: [])
    }
    let initial = Self.prepare(request, nativeSchema: nativeSchema, name: name, schema: schema)
    var responses: [ModelResponse] = []

    let first = try await call(initial, recordingInto: &responses)
    let firstBytes = Array(first.text.utf8)
    let firstCandidates = StructuredExtraction.candidates(in: firstBytes)
    let firstIssues: [JSONSchemaIssue]
    switch Self.verdict(firstCandidates.first, in: firstBytes, schema: schema) {
    case .valid(let json): return StructuredResult(json: json, mode: mode, wasRepaired: false, responses: responses)
    case .invalid(let issues): firstIssues = issues
    }

    var repair = initial
    if !first.text.allSatisfy(\.isWhitespace) { repair.messages.append(.assistant(first.text)) }
    repair.messages.append(.user(StructuredPrompt.repairRequest(issues: firstIssues, previousOutput: first.text, schema: schema)))
    let second = try await call(repair, recordingInto: &responses)
    let secondBytes = Array(second.text.utf8)
    let secondCandidates = StructuredExtraction.candidates(in: secondBytes)
    let secondIssues: [JSONSchemaIssue]
    switch Self.verdict(secondCandidates.first, in: secondBytes, schema: schema) {
    case .valid(let json): return StructuredResult(json: json, mode: mode, wasRepaired: true, responses: responses)
    case .invalid(let issues): secondIssues = issues
    }

    for candidate in secondCandidates.dropFirst() {
      if case .valid(let json) = Self.verdict(candidate, in: secondBytes, schema: schema) {
        return StructuredResult(json: json, mode: mode, wasRepaired: true, responses: responses)
      }
    }
    for candidate in firstCandidates.dropFirst() {
      if case .valid(let json) = Self.verdict(candidate, in: firstBytes, schema: schema) {
        return StructuredResult(json: json, mode: mode, wasRepaired: false, responses: responses)
      }
    }
    throw .invalid(issues: secondIssues, responses: responses)
  }

  private func call(_ request: ModelRequest, recordingInto responses: inout [ModelResponse]) async throws(StructuredError) -> ModelResponse {
    let response: ModelResponse
    do {
      response = try await provider.stream(request).collect()
    } catch {
      throw .model(error, responses: responses)
    }
    responses.append(response)
    switch response.stop {
    case .refusal(let category): throw .refused(category: category, responses: responses)
    case .contentFilter: throw .refused(category: Self.contentFilterCategory, responses: responses)
    case .maxTokens: throw .truncated(responses: responses)
    case .endTurn, .other: return response
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

  private static func verdict(_ candidate: StructuredJSONValue?, in bytes: [UInt8], schema: JSONValue) -> Verdict {
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
