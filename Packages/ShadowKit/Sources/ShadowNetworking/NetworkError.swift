import Foundation
import ShadowCore

public enum NetworkError: ShadowError {
  case encoding(String)
  case transport(URLError)
  case nonHTTPResponse
  case unacceptableStatus(code: Int, headers: [String: String], body: Data)
  case decoding(String)
  case cancelled
  case underlying(any Error)

  public var code: String {
    switch self {
    case .encoding: "network.encoding"
    case .transport: "network.transport"
    case .nonHTTPResponse: "network.non_http_response"
    case .unacceptableStatus: "network.unacceptable_status"
    case .decoding: "network.decoding"
    case .cancelled: "network.cancelled"
    case .underlying: "network.underlying"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .encoding(let reason): "The request body could not be encoded: \(reason)"
    case .transport(let error): error.localizedDescription
    case .nonHTTPResponse: "The server returned a response that is not HTTP."
    case .unacceptableStatus(let code, _, _): "The server responded with status \(code)."
    case .decoding(let reason): "The response could not be decoded: \(reason)"
    case .cancelled: "The request was cancelled."
    case .underlying(let error): error.localizedDescription
    }
  }

  public var retryAfter: Duration? {
    guard case .unacceptableStatus(_, let headers, _) = self, let value = headers["retry-after"]?.trimmingCharacters(in: .whitespaces) else { return nil }
    guard !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let seconds = Int(value) else { return nil }
    return .seconds(seconds)
  }
}
