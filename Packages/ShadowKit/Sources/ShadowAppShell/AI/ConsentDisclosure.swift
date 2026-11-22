import Foundation
import ShadowAI

/// One kind of data an app asks consent to send to a model provider, with the words the consent sheet shows for it. The app supplies its own; two are the
/// same disclosure when their id and data class match.
public nonisolated struct ConsentDisclosure: Hashable, Sendable {
  public let id: String
  public let dataClass: String
  private let titleText: @Sendable () -> String
  private let explanationText: @Sendable (_ provider: String) -> String

  public init(id: String, dataClass: String, title: @escaping @Sendable () -> String, explanation: @escaping @Sendable (_ provider: String) -> String) {
    self.id = id
    self.dataClass = dataClass
    titleText = title
    explanationText = explanation
  }

  public init?(_ request: AIConsentRequest, among disclosures: [ConsentDisclosure]) {
    guard let disclosure = disclosures.first(where: { $0.answers(request) }) else { return nil }
    self = disclosure
  }

  public var requirement: AIConsentRequirement { AIConsentRequirement(dataClass: dataClass, disclosure: id) }

  public var title: String { titleText() }

  public func explanation(provider: String) -> String { explanationText(provider) }

  public func answers(_ request: AIConsentRequest) -> Bool { id == request.disclosure && dataClass == request.dataClass }

  public static func == (lhs: ConsentDisclosure, rhs: ConsentDisclosure) -> Bool { lhs.id == rhs.id && lhs.dataClass == rhs.dataClass }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(dataClass)
  }
}

extension ModelProviderKind {
  public var displayName: String {
    switch self {
    case .anthropic: "Anthropic"
    case .openRouter: "OpenRouter"
    }
  }
}

extension Pace {
  public var displayName: String {
    switch self {
    case .swift: String(localized: "Swift", table: "AISettings", bundle: .module)
    case .steady: String(localized: "Steady", table: "AISettings", bundle: .module)
    case .meticulous: String(localized: "Meticulous", table: "AISettings", bundle: .module)
    }
  }
}
