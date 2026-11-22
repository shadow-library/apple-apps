import Foundation
import ShadowAI
import ShadowKeychain

public enum AIErrors {
  public static func presented(_ error: any Error, app: AppIdentity) -> PresentedError {
    switch error {
    case let error as TaskRouterError: PresentedError(headline: headline(for: error, app: app), detail: error.code)
    case let error as ModelError: PresentedError(headline: headline(for: error), detail: error.code)
    case let error as SecureStoreError: PresentedError(headline: headline(for: error, app: app), detail: detail(for: error))
    default: PresentedError(error)
    }
  }

  public static func headline(for error: TaskRouterError, app: AppIdentity) -> String {
    switch error {
    case .noRoute: String(localized: "No model is set up for this request. Choose one in AI settings.", table: "AISettings", bundle: .module)
    case .unrestrictedModelMissing: String(localized: "Unrestricted writing has no model chosen. Choose one in AI settings.", table: "AISettings", bundle: .module)
    case .providerMissing(let provider): String(localized: "\(provider.displayName) is not available in this version of the app.", table: "AISettings", bundle: .module)
    case .credentialMissing(let provider): String(localized: "Add your \(provider.displayName) key in AI settings first.", table: "AISettings", bundle: .module)
    case .consentRequired(let request) where request.provider == .demo: String(localized: "Allow the demo to use this first.", table: "AISettings", bundle: .module)
    case .consentRequired(let request): String(localized: "Allow \(app.displayName) to send this to \(request.provider.displayName) first.", table: "AISettings", bundle: .module)
    case .dailySpendLimitReached(_, let limit):
      String(localized: "Today's AI spend limit of \(money(limit)) has been reached. Raise it in AI settings or try again tomorrow.", table: "AISettings", bundle: .module)
    case .monthlySpendLimitReached(_, let limit):
      String(localized: "This month's AI spend limit of \(money(limit)) has been reached. Raise it in AI settings or wait until next month.", table: "AISettings", bundle: .module)
    case .spendUnavailable: String(localized: "Your AI spend so far could not be worked out, so nothing was sent.", table: "AISettings", bundle: .module)
    case .ledger: String(localized: "Your AI cost records could not be read, so nothing was sent.", table: "AISettings", bundle: .module)
    }
  }

  public static func headline(for error: ModelError) -> String {
    switch error {
    case .authentication: String(localized: "The provider did not accept this key.", table: "AISettings", bundle: .module)
    case .forbidden: String(localized: "This key is not allowed to make requests.", table: "AISettings", bundle: .module)
    case .insufficientCredits: String(localized: "The provider account has run out of credit.", table: "AISettings", bundle: .module)
    case .rateLimited, .overloaded: String(localized: "The provider is busy. Try again in a moment.", table: "AISettings", bundle: .module)
    case .server: String(localized: "The provider had a problem on its side. Try again later.", table: "AISettings", bundle: .module)
    case .transport(let code) where [.notConnectedToInternet, .dataNotAllowed].contains(code): String(localized: "This device is offline.", table: "AISettings", bundle: .module)
    case .transport: String(localized: "The provider could not be reached.", table: "AISettings", bundle: .module)
    case .cancelled: String(localized: "The check was cancelled.", table: "AISettings", bundle: .module)
    default: String(localized: "The provider's reply could not be used.", table: "AISettings", bundle: .module)
    }
  }

  public static func headline(for error: SecureStoreError, app: AppIdentity) -> String {
    String(localized: "Your keychain could not be read or written. Check that \(app.displayName) may use it.", table: "AISettings", bundle: .module)
  }

  public static func money(_ cost: Cost) -> String {
    (Decimal(cost.nanoUSD) / Decimal(Cost.nanoUSDPerUSD)).formatted(.currency(code: "USD"))
  }

  private static func detail(for error: SecureStoreError) -> String {
    guard case .unexpectedStatus(let status) = error else { return error.code }
    return "\(error.code) (\(status))"
  }
}
