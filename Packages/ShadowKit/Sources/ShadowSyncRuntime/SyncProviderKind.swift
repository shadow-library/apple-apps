public enum SyncProviderKind: String, Sendable, Codable, CaseIterable {
  case iCloud
  case localFolder
  case s3
  case oneDrive
  case googleDrive
}
