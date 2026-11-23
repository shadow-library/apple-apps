import Foundation

/// Who the shell works for: the app's reverse-DNS id, which names its keychain services and defaults keys, and the words its screens use for the app and
/// for what it keeps in its vault. An app makes one and passes it in; the shell never names an app itself.
public nonisolated struct AppIdentity: Equatable, Sendable {
  /// `com.shadow.apps.<app>`.
  public let id: String
  public let displayName: String
  /// The vault as a countable noun inside a sentence: "Your library is the same on all your devices", "Another library is there".
  public let vaultNoun: String
  /// The same noun capitalized for a label or a button: "Library", "Move Library".
  public let vaultTitle: String
  /// The bucket name the S3 form shows as its placeholder, such as "my-novels".
  public let exampleBucketName: String
  /// The About screen shows a privacy policy, support or contact row only for a value set here; an unset one leaves no row.
  public let privacyPolicyURL: URL?
  public let supportURL: URL?
  /// An email address, offered as a mailto link.
  public let contactAddress: String?

  public init(
    id: String, displayName: String, vaultNoun: String, vaultTitle: String, exampleBucketName: String, privacyPolicyURL: URL? = nil, supportURL: URL? = nil,
    contactAddress: String? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.vaultNoun = vaultNoun
    self.vaultTitle = vaultTitle
    self.exampleBucketName = exampleBucketName
    self.privacyPolicyURL = privacyPolicyURL
    self.supportURL = supportURL
    self.contactAddress = contactAddress
  }

  public var aiKeychainService: String { "\(id).ai" }
  public var aiSettingsKey: String { "\(id).ai.settings.v1" }
  public var recoveryRecipientKeyPrefix: String { "\(id).sync.recovery-recipient." }
  public var recoveryOfferDeclinedKeyPrefix: String { "\(id).sync.recovery-offer-declined." }

  /// Where OpenRouter's sign-in returns, under the app's id as a URL scheme. `ASWebAuthenticationSession` catches it itself, so no app registers it.
  public var openRouterCallback: URL {
    var components = URLComponents()
    components.scheme = id
    components.host = "openrouter-sign-in"
    guard let url = components.url else { preconditionFailure("An app id is always a valid URL scheme.") }
    return url
  }
}
