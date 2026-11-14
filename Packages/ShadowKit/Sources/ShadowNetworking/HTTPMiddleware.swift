import Foundation

public protocol HTTPMiddleware: Sendable {
  func intercept(_ request: URLRequest, next: (URLRequest) async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse)
}

public struct BearerTokenMiddleware: HTTPMiddleware {
  private let token: @Sendable () async throws -> String?

  public init(token: @escaping @Sendable () async throws -> String?) {
    self.token = token
  }

  public func intercept(_ request: URLRequest, next: (URLRequest) async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse) {
    guard let token = try await token() else { return try await next(request) }
    var authorized = request
    authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return try await next(authorized)
  }
}
