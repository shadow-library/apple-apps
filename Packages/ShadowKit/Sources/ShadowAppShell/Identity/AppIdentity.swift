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

  public init(id: String, displayName: String, vaultNoun: String, vaultTitle: String, exampleBucketName: String) {
    self.id = id
    self.displayName = displayName
    self.vaultNoun = vaultNoun
    self.vaultTitle = vaultTitle
    self.exampleBucketName = exampleBucketName
  }

  public var aiKeychainService: String { "\(id).ai" }
  public var aiSettingsKey: String { "\(id).ai.settings.v1" }
  public var recoveryRecipientKeyPrefix: String { "\(id).sync.recovery-recipient." }
  public var recoveryOfferDeclinedKeyPrefix: String { "\(id).sync.recovery-offer-declined." }
}
