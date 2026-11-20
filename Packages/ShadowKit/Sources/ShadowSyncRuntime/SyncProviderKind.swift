public enum SyncProviderKind: String, Sendable, Codable, CaseIterable {
  case iCloud
  case localFolder
  case s3
  case oneDrive
  case googleDrive

  /// A location of such a kind is attached only with an account binding, so an account switch is always noticed.
  public var distinguishesAccounts: Bool {
    switch self {
    case .iCloud, .oneDrive, .googleDrive: true
    case .localFolder, .s3: false
    }
  }
}
