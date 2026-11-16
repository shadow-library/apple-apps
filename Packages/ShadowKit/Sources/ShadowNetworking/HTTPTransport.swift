import Foundation

public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else { throw NetworkError.nonHTTPResponse }
    return (data, httpResponse)
  }
}

extension HTTPURLResponse {
  public var lowercasedHeaderFields: [String: String] {
    let fields = allHeaderFields.compactMap { name, value -> (String, String)? in
      guard let name = name as? String, let value = value as? String else { return nil }
      return (name.lowercased(), value)
    }
    return Dictionary(fields) { first, _ in first }
  }
}
