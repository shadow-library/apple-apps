import ShadowCore

// The reference builds no pattern Swift's engine could refuse; were one refused, every caller stops rather than let a secret through, as the reference does when it throws.
enum DisclosureError: ShadowError, Equatable {
  case pattern(JSRegexError)
  case leakFindingCycle

  var code: String {
    switch self {
    case .pattern: "disclosure.pattern"
    case .leakFindingCycle: "disclosure.leak-finding-cycle"
    }
  }

  var errorDescription: String? {
    switch self {
    case .pattern(let error): "A withheld passage could not be turned into a pattern: \(error.errorDescription ?? error.code)"
    case .leakFindingCycle: "A writer note quotes a knowledge-leak finding that leads back to itself."
    }
  }
}
