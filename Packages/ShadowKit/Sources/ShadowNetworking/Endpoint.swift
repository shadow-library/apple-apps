import Foundation

public enum HTTPMethod: String, Sendable {
  case get = "GET"
  case post = "POST"
  case put = "PUT"
  case patch = "PATCH"
  case delete = "DELETE"
}

public struct EmptyResponse: Decodable, Sendable, Equatable {
  public init() {}
}

public struct Endpoint<Response: Decodable & Sendable>: Sendable {
  public var method: HTTPMethod
  public var path: String
  public var queryItems: [URLQueryItem]
  public var headers: [String: String]
  public var body: (any Encodable & Sendable)?

  public init(
    method: HTTPMethod = .get,
    path: String,
    queryItems: [URLQueryItem] = [],
    headers: [String: String] = [:],
    body: (any Encodable & Sendable)? = nil,
    responseType: Response.Type = Response.self
  ) {
    self.method = method
    self.path = path
    self.queryItems = queryItems
    self.headers = headers
    self.body = body
  }
}
