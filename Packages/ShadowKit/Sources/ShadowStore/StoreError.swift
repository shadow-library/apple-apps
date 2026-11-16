import Foundation

import ShadowCore

public enum StoreError: ShadowError {
  case database(String)

  public var code: String {
    switch self {
    case .database: "store.database"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .database(let message): "Database failure: \(message)"
    }
  }
}
