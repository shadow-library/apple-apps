import Foundation

public struct S3Credentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let accessKeyID: String
  public let secretAccessKey: String
  public let sessionToken: String?

  public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) throws(S3ConfigurationError) {
    guard Self.isToken(accessKeyID) else { throw .invalidCredentials("The access key id must be printable ASCII without spaces.") }
    guard Self.isToken(secretAccessKey) else { throw .invalidCredentials("The secret access key must be printable ASCII without spaces.") }
    guard sessionToken.map(Self.isToken) ?? true else { throw .invalidCredentials("The session token must be printable ASCII without spaces.") }
    self.accessKeyID = accessKeyID
    self.secretAccessKey = secretAccessKey
    self.sessionToken = sessionToken
  }

  public var description: String {
    "S3Credentials(accessKeyID: \(accessKeyID), secretAccessKey: <redacted>, sessionToken: \(sessionToken == nil ? "none" : "<redacted>"))"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: ["accessKeyID": accessKeyID, "secretAccessKey": "<redacted>", "sessionToken": sessionToken == nil ? "none" : "<redacted>"],
      displayStyle: .struct
    )
  }

  private static func isToken(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { (0x21...0x7E).contains($0) }
  }
}
