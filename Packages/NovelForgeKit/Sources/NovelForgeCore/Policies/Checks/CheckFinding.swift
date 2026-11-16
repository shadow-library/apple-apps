enum CheckSeverity: String, Equatable, Sendable {
  case hard
  case soft
}

struct CheckFinding: Equatable, Sendable {
  let severity: CheckSeverity
  let text: String
}
