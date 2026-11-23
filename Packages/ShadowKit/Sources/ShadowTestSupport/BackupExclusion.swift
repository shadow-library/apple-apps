import Foundation

public enum BackupExclusion {
  private static let attribute = "com.apple.metadata:com_apple_backup_excludeItem"

  /// Reads the attribute itself: the resource value reports it only after the metadata layer catches up, which CI runners may not do in time.
  public static func isExcluded(_ url: URL) -> Bool {
    getxattr(url.path(percentEncoded: false), attribute, nil, 0, 0, 0) > 0
  }
}
