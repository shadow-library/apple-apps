import ShadowCore

public enum MessageRole: String, Sendable, Codable {
  case user
  case assistant
}

public struct ModelMessage: Sendable, Equatable, Codable {
  public var role: MessageRole
  public var text: String

  public init(role: MessageRole, text: String) {
    self.role = role
    self.text = text
  }

  public static func user(_ text: String) -> ModelMessage { ModelMessage(role: .user, text: text) }

  public static func assistant(_ text: String) -> ModelMessage { ModelMessage(role: .assistant, text: text) }
}

public struct ContextSegment: Sendable, Equatable, Codable {
  public var text: String
  /// True on the last segment that stays byte-identical between calls; the adapter puts a cache breakpoint after it.
  public var endsStablePrefix: Bool

  public init(text: String, endsStablePrefix: Bool = false) {
    self.text = text
    self.endsStablePrefix = endsStablePrefix
  }
}

public enum ResponseFormat: Sendable, Equatable {
  case text
  case json(name: String, schema: JSONValue)
}

public struct ModelRequest: Sendable, Equatable {
  private static let schemaNameLimit = 64

  public var model: String
  public var system: [ContextSegment]
  public var messages: [ModelMessage]
  public var maxOutputTokens: Int
  public var effort: Effort?
  public var format: ResponseFormat
  public var cachesConversation: Bool

  public init(
    model: String,
    system: [ContextSegment],
    messages: [ModelMessage],
    maxOutputTokens: Int,
    effort: Effort? = nil,
    format: ResponseFormat = .text,
    cachesConversation: Bool = false
  ) {
    self.model = model
    self.system = system
    self.messages = messages
    self.maxOutputTokens = maxOutputTokens
    self.effort = effort
    self.format = format
    self.cachesConversation = cachesConversation
  }

  public func validated() throws(ModelError) -> ModelRequest {
    guard !model.allSatisfy(\.isWhitespace) else { throw .invalidRequest("The request names no model.") }
    guard let last = messages.last else { throw .invalidRequest("The request has no messages.") }
    guard last.role == .user else { throw .invalidRequest("The last message must come from the user.") }
    guard !messages.contains(where: { $0.text.allSatisfy(\.isWhitespace) }) else { throw .invalidRequest("A message has no text.") }
    guard !system.contains(where: { $0.text.allSatisfy(\.isWhitespace) }) else { throw .invalidRequest("A system segment has no text.") }
    guard maxOutputTokens >= 1 else { throw .invalidRequest("The output limit must be at least one token.") }
    guard system.count(where: \.endsStablePrefix) <= 1 else { throw .invalidRequest("Only one system segment may end the stable prefix.") }
    guard case .json(let name, let schema) = format else { return self }
    guard !name.isEmpty else { throw .invalidRequest("The response schema has no name.") }
    guard name.count <= Self.schemaNameLimit, name.unicodeScalars.allSatisfy(Self.isSchemaNameScalar) else {
      throw .invalidRequest("The response schema name may use only letters, digits, underscores and hyphens, up to \(Self.schemaNameLimit) characters.")
    }
    guard case .object = schema else { throw .invalidRequest("The response schema must be a JSON object.") }
    return self
  }

  private static func isSchemaNameScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9", "_", "-": true
    default: false
    }
  }
}
