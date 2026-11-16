import Foundation
import GRDB

public struct StoreMigration: Sendable {
  public let identifier: String
  public let migrate: @Sendable (Database) throws -> Void

  public init(identifier: String, migrate: @escaping @Sendable (Database) throws -> Void) {
    self.identifier = identifier
    self.migrate = migrate
  }
}

public enum StoreLocation: Sendable {
  case file(URL)
  case inMemory
}

public enum StateScope: Int, Sendable, CaseIterable {
  case vault = 0
  case own = 1
}

public enum RemintMode: Sendable {
  case keepState
  /// Timestamps restart above everything public (acknowledged or observed), so only unsent changes shed a wrong device clock.
  case rebuild
}

public enum RevisionParent: Sendable, Equatable {
  case head
  case none
  case revision(String)
}

public struct LoggedChange: Sendable, Equatable {
  public let sequence: Int64
  public let line: Data
}
