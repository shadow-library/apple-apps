import Foundation
import ShadowNetworking

enum OpenRouterFailure {
  private static let maxMessageLength = 300
  private static let errorBodyLimit = 65_536
  private static let inFlightBudget = "openrouter_in_flight_budget"
  private static let dataPolicyPhrase = "data policy"
  private static let redaction = "<redacted>"

  static func error(_ body: OpenRouterErrorBody, status: Int?, retryAfter: Duration?, afterText: Bool, secret: String?) -> ModelError {
    let type = body.metadata?.errorType
    let code = (body.code.flatMap { (400...599).contains($0) ? $0 : nil }) ?? status
    let message = message(of: body, fallback: code.map { "The provider reported an error (status \($0))." } ?? "The provider reported an error.", secret: secret)
    if afterText { return .midStream(code: type ?? code.map(String.init) ?? "error", message: message) }
    if isDataPolicyMismatch(message) { return .dataPolicy(message) }
    let limitSource = body.metadata?.limitSource
    switch type {
    case "rate_limit_exceeded": return .rateLimited(retryAfter: retryAfter)
    case "provider_overloaded": return .overloaded(retryAfter: retryAfter)
    case "payment_required": return limitSource == inFlightBudget ? .rateLimited(retryAfter: retryAfter) : .insufficientCredits
    case "authentication": return .authentication
    case "permission_denied", "content_policy_violation", "refusal": return .forbidden(message)
    case "not_found": return .noEligibleModel
    default: break
    }
    guard let code else { return .midStream(code: type ?? "error", message: message) }
    switch code {
    case 401: return .authentication
    case 402: return limitSource == inFlightBudget ? .rateLimited(retryAfter: retryAfter) : .insufficientCredits
    case 403: return .forbidden(message)
    case 404, 503: return .noEligibleModel
    case 408: return .transport(.timedOut)
    case 429: return .rateLimited(retryAfter: retryAfter)
    case 400...499: return .invalidRequest(message)
    case 500...599: return .server(status: code)
    default: return .malformedResponse("The provider responded with unexpected status \(code).")
    }
  }

  /// The body's error object refines the status; the raw body is never quoted, since it may echo the request.
  static func response(_ response: HTTPURLResponse, body: Data, secret: String?) -> ModelError {
    let status = response.statusCode
    let retryAfter = retryAfter(response)
    guard (400...599).contains(status) else { return ModelError(.unacceptableStatus(code: status, headers: [:], body: Data())) }
    let envelope = try? JSONDecoder().decode(OpenRouterErrorEnvelope.self, from: body)
    var error = envelope?.error ?? OpenRouterErrorBody()
    error.code = status
    return Self.error(error, status: status, retryAfter: retryAfter, afterText: false, secret: secret)
  }

  static func response(_ response: HTTPStreamingResponse, secret: String?) async -> ModelError {
    var body = Data()
    do {
      for try await chunk in response.body {
        body.append(chunk.prefix(errorBodyLimit - body.count))
        if body.count >= errorBodyLimit { break }
      }
    } catch {
      return ModelError(converting: error)
    }
    if Task.isCancelled { return .cancelled }
    return Self.response(response.response, body: body, secret: secret)
  }

  static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
    return NetworkError.unacceptableStatus(code: response.statusCode, headers: ["retry-after": value], body: Data()).retryAfter
  }

  // OpenRouter documents no code or error_type for a data-policy mismatch, so its message is the only signal.
  private static func isDataPolicyMismatch(_ message: String) -> Bool {
    message.localizedCaseInsensitiveContains(dataPolicyPhrase)
  }

  private static func message(of error: OpenRouterErrorBody, fallback: String, secret: String?) -> String {
    let text = nonEmpty(error.message) ?? fallback
    let reason = nonEmpty(error.metadata?.rawMessage).map { reason in nonEmpty(error.metadata?.providerName).map { "\($0): \(reason)" } ?? reason }
    var combined = reason.map { "\(text) (\($0))" } ?? text
    if let secret, !secret.isEmpty { combined = combined.replacingOccurrences(of: secret, with: redaction) }
    let result = trimmed(combined)
    return result.isEmpty ? fallback : result
  }

  private static func trimmed(_ message: String) -> String {
    let collapsed = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard collapsed.count > maxMessageLength else { return collapsed }
    return "\(collapsed.prefix(maxMessageLength - 1))…"
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.allSatisfy(\.isWhitespace) else { return nil }
    return value
  }
}
