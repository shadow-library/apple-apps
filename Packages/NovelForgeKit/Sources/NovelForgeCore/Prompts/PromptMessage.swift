struct PromptMessage: Equatable, Sendable {
  enum Role: String, Sendable {
    case system
    case user
    case assistant
  }

  let role: Role
  let text: String

  init(_ role: Role, _ text: String) {
    self.role = role
    self.text = text
  }
}
