import Foundation
import ShadowNetworking

enum AnthropicErrors {
  static let messageLimit = 300

  struct Detail: Decodable {
    let type: String
    let message: String?
  }

  private struct Envelope: Decodable {
    let error: Detail
  }

  static func detail(in data: Data) -> Detail? {
    try? JSONDecoder().decode(Envelope.self, from: data).error
  }

  static func http(status: Int, headers: [String: String], body: Data) -> ModelError {
    let network = NetworkError.unacceptableStatus(code: status, headers: headers, body: body)
    guard let detail = detail(in: body) else { return ModelError(network) }
    let message = truncated(detail.message)
    switch detail.type {
    case "authentication_error": return .authentication
    case "permission_error": return .forbidden(message)
    case "billing_error": return .insufficientCredits
    case "rate_limit_error": return .rateLimited(retryAfter: network.retryAfter)
    case "overloaded_error": return .overloaded(retryAfter: network.retryAfter)
    case "invalid_request_error", "not_found_error", "request_too_large", "conflict_error": return .invalidRequest(message)
    case "api_error", "timeout_error": return (500...599).contains(status) ? .server(status: status) : ModelError(network)
    default: return ModelError(network)
    }
  }

  /// `api_error` is the type the API documents for a 500, so an in-stream one before any text stays retryable like its HTTP form.
  static func inStream(_ detail: Detail, afterText: Bool) -> ModelError {
    let message = truncated(detail.message)
    guard !afterText else { return .midStream(code: detail.type, message: message) }
    switch detail.type {
    case "rate_limit_error": return .rateLimited(retryAfter: nil)
    case "overloaded_error": return .overloaded(retryAfter: nil)
    case "api_error": return .server(status: 500)
    default: return .midStream(code: detail.type, message: message)
    }
  }

  static func truncated(_ message: String?) -> String {
    String((message ?? "").prefix(messageLimit))
  }
}
