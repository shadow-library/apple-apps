import ShadowCore
import ShadowText

enum HardLineScope: String, Sendable {
  case supplied
  case background
}

enum HardLineRule: String, Sendable {
  case standaloneTerm = "standalone-term"
  case minorWithSexualContent = "minor-with-sexual-content"
  case minorWithExplicitAct = "minor-with-explicit-act"
}

struct HardLineLexicon: Sendable {
  var standalone: [JSRegex]
  var minor: [JSRegex]
  var sexual: [JSRegex]
  var explicit: [JSRegex]
}

struct ScreenedText: Equatable, Sendable {
  var text: String
  var scope: HardLineScope
  var source: String
  var sourceRefs: [String]?
}

struct HardLineHit: Equatable, Sendable {
  var rule: HardLineRule
  var source: String
  var sourceRefs: [String]
}

struct HardLineContentPart: Equatable, Sendable {
  var text: String?
}

enum HardLineContent: Equatable, Sendable {
  case text(String)
  case parts([HardLineContentPart])
  case other
}

struct WireMessage: Equatable, Sendable {
  var content: HardLineContent
}

struct ContextSection: Equatable, Sendable {
  var key: String
  var rendered: String
  var sourceRefs: [String]
}

struct RequestGuard: Sendable {
  var screen: @Sendable ([WireMessage]) throws(HardLineError) -> Void
  var systemLine: String
}

enum HardLineError: ShadowError, Equatable {
  case declined(source: String, rule: HardLineRule, sourceRefs: [String])

  var code: String { "AI_015" }

  var errorDescription: String? {
    switch self {
    case .declined(let source, _, _):
      "This request was declined before it reached a model: \(source) appears to involve sexual content with a minor, which Novel Forge never writes in any mode"
    }
  }
}
