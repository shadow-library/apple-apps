import Foundation
import ShadowCore
import ShadowNetworking

public enum ModelError: ShadowError, Equatable {
  case rateLimited(retryAfter: Duration?)
  case overloaded(retryAfter: Duration?)
  case server(status: Int)
  case transport(URLError.Code)
  case midStream(code: String, message: String)
  case invalidRequest(String)
  case authentication
  case forbidden(String)
  case insufficientCredits
  case dataPolicy(String)
  case noEligibleModel
  case malformedResponse(String)
  /// The cost ledger could not record the call, so it was not sent.
  case notRecorded
  case cancelled

  private static let transientTransportCodes: Set<URLError.Code> = [
    .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .callIsActive,
  ]

  private static let permanentServerStatuses: Set<Int> = [501, 505]

  public var code: String {
    switch self {
    case .rateLimited: "model.rate_limited"
    case .overloaded: "model.overloaded"
    case .server: "model.server"
    case .transport: "model.transport"
    case .midStream: "model.mid_stream"
    case .invalidRequest: "model.invalid_request"
    case .authentication: "model.authentication"
    case .forbidden: "model.forbidden"
    case .insufficientCredits: "model.insufficient_credits"
    case .dataPolicy: "model.data_policy"
    case .noEligibleModel: "model.no_eligible_model"
    case .malformedResponse: "model.malformed_response"
    case .notRecorded: "model.not_recorded"
    case .cancelled: "model.cancelled"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .rateLimited(let retryAfter?): "The provider asked to slow down for \(retryAfter.components.seconds) seconds."
    case .rateLimited(nil): "The provider asked to slow down."
    case .overloaded(let retryAfter?): "The provider is overloaded; it asked to wait \(retryAfter.components.seconds) seconds."
    case .overloaded(nil): "The provider is overloaded right now."
    case .server(let status): "The provider had a problem on its side (status \(status))."
    case .transport(.timedOut): "The connection to the provider timed out."
    case .transport(.notConnectedToInternet), .transport(.dataNotAllowed): "This device is offline."
    case .transport(let code): "The connection to the provider failed (code \(code.rawValue))."
    case .midStream(_, let message): "The provider stopped partway through the reply: \(message)"
    case .invalidRequest(let message): "The provider did not accept the request: \(message)"
    case .authentication: "The provider did not accept the key."
    case .forbidden(let message): "The key is not allowed to do this: \(message)"
    case .insufficientCredits: "The provider account has run out of credit."
    case .dataPolicy(let message): "No model is available under the account's data policy: \(message)"
    case .noEligibleModel: "No model is available for this request."
    case .malformedResponse(let message): "The provider's reply could not be read: \(message)"
    case .notRecorded: "The request was not sent because its cost could not be recorded on this device."
    case .cancelled: "The request was cancelled."
    }
  }

  public var isRetryable: Bool {
    switch self {
    case .rateLimited, .overloaded: true
    case .server(let status): (500...599).contains(status) && !Self.permanentServerStatuses.contains(status)
    case .transport(let code): Self.transientTransportCodes.contains(code)
    case .midStream, .invalidRequest, .authentication, .forbidden, .insufficientCredits, .dataPolicy, .noEligibleModel, .malformedResponse, .notRecorded, .cancelled: false
    }
  }

  var retryAfter: Duration? {
    switch self {
    case .rateLimited(let retryAfter), .overloaded(let retryAfter): retryAfter
    default: nil
    }
  }

  /// The generic mapping by status class; adapters refine it with the provider's error body.
  public init(_ error: NetworkError) {
    switch error {
    case .encoding(let reason): self = .invalidRequest(reason)
    case .transport(let error): self = error.code == .cancelled ? .cancelled : .transport(error.code)
    case .nonHTTPResponse: self = .malformedResponse("The provider's response is not HTTP.")
    case .unacceptableStatus(let status, _, _): self = Self.status(status, retryAfter: error.retryAfter)
    case .decoding(let reason): self = .malformedResponse(reason)
    case .cancelled: self = .cancelled
    case .underlying(let error): self = ModelError(converting: error)
    }
  }

  /// Keeps a `ModelError`, maps `NetworkError`, `URLError` and cancellation, and treats anything else as an unreadable reply.
  public init(converting error: any Error) {
    switch error {
    case let error as ModelError: self = error
    case let error as NetworkError: self = ModelError(error)
    case let error as URLError: self = ModelError(.transport(error))
    case is CancellationError: self = .cancelled
    default: self = .malformedResponse(String(describing: error))
    }
  }

  private static func status(_ status: Int, retryAfter: Duration?) -> ModelError {
    switch status {
    case 401: .authentication
    case 402: .insufficientCredits
    case 403: .forbidden("The provider responded with status 403.")
    case 408: .transport(.timedOut)
    case 429: .rateLimited(retryAfter: retryAfter)
    case 503, 529: .overloaded(retryAfter: retryAfter)
    case 400...499: .invalidRequest("The provider responded with status \(status).")
    case 500...599: .server(status: status)
    default: .malformedResponse("The provider responded with unexpected status \(status).")
    }
  }
}
