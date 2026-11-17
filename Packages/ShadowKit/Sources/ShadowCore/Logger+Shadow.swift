import Foundation
import OSLog

extension Logger {
  public static let fallbackSubsystem = "com.shadow.library.shadowkit"

  public init(category: String, bundle: Bundle = .main) {
    self.init(subsystem: bundle.bundleIdentifier ?? Self.fallbackSubsystem, category: category)
  }
}
