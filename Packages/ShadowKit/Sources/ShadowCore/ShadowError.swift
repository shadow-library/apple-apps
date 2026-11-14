import Foundation

public protocol ShadowError: LocalizedError, Sendable, CustomStringConvertible {
  var code: String { get }
}

extension ShadowError {
  public var description: String { "\(code): \(errorDescription ?? String(describing: Self.self))" }
}
