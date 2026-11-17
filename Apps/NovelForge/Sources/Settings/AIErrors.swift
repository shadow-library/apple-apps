import Foundation
import ShadowAI
import ShadowKeychain

enum AIErrors {
  static func presented(_ error: any Error) -> PresentedError {
    switch error {
    case let error as TaskRouterError: PresentedError(headline: headline(for: error), detail: error.code)
    case let error as ModelError: PresentedError(headline: headline(for: error), detail: error.code)
    case let error as SecureStoreError: PresentedError(headline: headline(for: error), detail: detail(for: error))
    default: PresentedError(error)
    }
  }

  static func headline(for error: TaskRouterError) -> String {
    switch error {
    case .noRoute: String(localized: "No model is set up for this request. Choose one in AI settings.", table: "Settings")
    case .unrestrictedModelMissing: String(localized: "Unrestricted writing has no model chosen. Choose one in AI settings.", table: "Settings")
    case .providerMissing(let provider): String(localized: "\(provider.displayName) is not available in this version of the app.", table: "Settings")
    case .credentialMissing(let provider): String(localized: "Add your \(provider.displayName) key in AI settings first.", table: "Settings")
    case .consentRequired(let request): String(localized: "Allow Novel Forge to send this to \(request.provider.displayName) first.", table: "Settings")
    case .dailySpendLimitReached(_, let limit):
      String(localized: "Today's AI spend limit of \(money(limit)) has been reached. Raise it in AI settings or try again tomorrow.", table: "Settings")
    case .monthlySpendLimitReached(_, let limit):
      String(localized: "This month's AI spend limit of \(money(limit)) has been reached. Raise it in AI settings or wait until next month.", table: "Settings")
    case .spendUnavailable: String(localized: "Your AI spend so far could not be worked out, so nothing was sent.", table: "Settings")
    case .ledger: String(localized: "Your AI cost records could not be read, so nothing was sent.", table: "Settings")
    }
  }

  static func headline(for error: ModelError) -> String {
    switch error {
    case .authentication: String(localized: "The provider did not accept this key.", table: "Settings")
    case .forbidden: String(localized: "This key is not allowed to make requests.", table: "Settings")
    case .insufficientCredits: String(localized: "The provider account has run out of credit.", table: "Settings")
    case .rateLimited, .overloaded: String(localized: "The provider is busy. Try again in a moment.", table: "Settings")
    case .server: String(localized: "The provider had a problem on its side. Try again later.", table: "Settings")
    case .transport(let code) where [.notConnectedToInternet, .dataNotAllowed].contains(code): String(localized: "This device is offline.", table: "Settings")
    case .transport: String(localized: "The provider could not be reached.", table: "Settings")
    case .cancelled: String(localized: "The check was cancelled.", table: "Settings")
    default: String(localized: "The provider's reply could not be used.", table: "Settings")
    }
  }

  static func headline(for error: SecureStoreError) -> String {
    String(localized: "Your keychain could not be read or written. Check that Novel Forge may use it.", table: "Settings")
  }

  static func money(_ cost: Cost) -> String {
    (Decimal(cost.nanoUSD) / Decimal(Cost.nanoUSDPerUSD)).formatted(.currency(code: "USD"))
  }

  private static func detail(for error: SecureStoreError) -> String {
    guard case .unexpectedStatus(let status) = error else { return error.code }
    return "\(error.code) (\(status))"
  }
}
