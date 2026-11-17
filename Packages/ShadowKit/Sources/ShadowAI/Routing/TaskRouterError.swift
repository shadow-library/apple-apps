import Foundation
import ShadowCore
import ShadowStore

public struct AIConsentRequest: Sendable, Equatable {
  public let provider: ModelProviderKind
  public let host: String
  public let dataClass: String
  public let disclosure: String

  public init(provider: ModelProviderKind, host: String, dataClass: String, disclosure: String) {
    self.provider = provider
    self.host = host
    self.dataClass = dataClass
    self.disclosure = disclosure
  }
}

public enum TaskRouterError: ShadowError {
  case noRoute(task: ModelTask, pace: Pace)
  case unrestrictedModelMissing
  case providerMissing(ModelProviderKind)
  case credentialMissing(ModelProviderKind)
  case consentRequired(AIConsentRequest)
  case dailySpendLimitReached(spent: Cost, limit: Cost)
  case monthlySpendLimitReached(spent: Cost, limit: Cost)
  /// The calendar gave no day or month to total the spend over, so the cap could not be checked and the call was refused.
  case spendUnavailable
  case ledger(StoreError)

  public var code: String {
    switch self {
    case .noRoute: "routing.no_route"
    case .unrestrictedModelMissing: "routing.unrestricted_model_missing"
    case .providerMissing: "routing.provider_missing"
    case .credentialMissing: "routing.credential_missing"
    case .consentRequired: "routing.consent_required"
    case .dailySpendLimitReached: "routing.daily_spend_limit"
    case .monthlySpendLimitReached: "routing.monthly_spend_limit"
    case .spendUnavailable: "routing.spend_unavailable"
    case .ledger: "routing.ledger"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .noRoute(let task, let pace): "No model is set up for \(task.rawValue) at the \(pace.rawValue) pace."
    case .unrestrictedModelMissing: "Unrestricted writing has no model assigned."
    case .providerMissing(let provider): "\(provider.rawValue) is not connected."
    case .credentialMissing(let provider): "There is no key for \(provider.rawValue)."
    case .consentRequired(let request): "Sending \(request.dataClass) to \(request.host) needs your consent."
    case .dailySpendLimitReached: "Today's AI spend limit has been reached."
    case .monthlySpendLimitReached: "This month's AI spend limit has been reached."
    case .spendUnavailable: "The AI spend so far could not be worked out, so the request was not sent."
    case .ledger(let error): "The cost ledger could not be read: \(error.code)"
    }
  }
}
