#if os(macOS)
  import Foundation
  import ServiceManagement

  nonisolated enum LoginItemStatus: Sendable, Hashable {
    case notRegistered
    case enabled
    /// Registered, but the user has to allow it in System Settings, or later turned it off there.
    case requiresApproval
    case notFound
  }

  nonisolated struct LoginItemError: Error, Sendable, Hashable {
    enum Reason: Sendable, Hashable {
      /// `kSMErrorInvalidSignature`: the app is not signed as the system requires, as a build without a team.
      case invalidSignature
      case failed(domain: String, code: Int)
    }

    let reason: Reason

    var code: String {
      switch reason {
      case .invalidSignature: "login-item.invalid-signature"
      case .failed(let domain, let code): "login-item.\(domain).\(code)"
      }
    }
  }

  /// Whether the system opens Novel Forge when the user logs in: `SMAppService.mainApp`, or a fake in tests.
  @MainActor
  protocol LoginItem: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws(LoginItemError)
    func unregister() throws(LoginItemError)
    func openSystemSettingsLoginItems()
  }

  /// `SMAppService` needs a code-signed app; an unsigned one is refused with an error, never a crash.
  final class SystemLoginItem: LoginItem {
    var status: LoginItemStatus {
      switch SMAppService.mainApp.status {
      case .notRegistered: .notRegistered
      case .enabled: .enabled
      case .requiresApproval: .requiresApproval
      case .notFound: .notFound
      @unknown default: .notFound
      }
    }

    /// Registering one already registered, or one the user has yet to allow, is not a failure: `status` says where it stands.
    func register() throws(LoginItemError) {
      do {
        try SMAppService.mainApp.register()
      } catch {
        try Self.refuse(error, unless: [kSMErrorAlreadyRegistered, kSMErrorLaunchDeniedByUser])
      }
    }

    func unregister() throws(LoginItemError) {
      do {
        try SMAppService.mainApp.unregister()
      } catch {
        try Self.refuse(error, unless: [kSMErrorJobNotFound])
      }
    }

    func openSystemSettingsLoginItems() {
      SMAppService.openSystemSettingsLoginItems()
    }

    private static func refuse(_ error: any Error, unless accepted: Set<Int>) throws(LoginItemError) {
      let error = error as NSError
      let isServiceManagement = error.domain == SMAppServiceErrorDomain
      if isServiceManagement, accepted.contains(error.code) { return }
      if isServiceManagement, error.code == kSMErrorInvalidSignature { throw LoginItemError(reason: .invalidSignature) }
      throw LoginItemError(reason: .failed(domain: error.domain, code: error.code))
    }
  }

  /// While XCTest hosts the app: the login item of the Mac running the tests is never read or changed.
  final class InertLoginItem: LoginItem {
    var status: LoginItemStatus { .notRegistered }
    func register() throws(LoginItemError) {}
    func unregister() throws(LoginItemError) {}
    func openSystemSettingsLoginItems() {}
  }
#endif
