import ShadowCore
import ShadowSync

public enum CloudKitZoneError: ShadowError, Equatable {
  /// A failure the provider passes on as it is: quota, rate limits, sign-in, reachability and the rest.
  case storage(StorageError)
  case changeTokenExpired
  case zoneMissing(CloudKitZoneLoss)
  /// The server holds a record of that name and the save asked for none.
  case recordChanged
  case recordMissing
  /// The request carried too many records or too many bytes.
  case limitExceeded

  public var code: String {
    switch self {
    case .storage(let error): error.code
    case .changeTokenExpired: "cloudkit.change_token_expired"
    case .zoneMissing: "cloudkit.zone_missing"
    case .recordChanged: "cloudkit.record_changed"
    case .recordMissing: "cloudkit.record_missing"
    case .limitExceeded: "cloudkit.limit_exceeded"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .storage(let error): error.errorDescription
    case .changeTokenExpired: "The CloudKit change token expired."
    case .zoneMissing(let loss): loss.explanation
    case .recordChanged: "A CloudKit record of that name already exists."
    case .recordMissing: "The CloudKit record does not exist."
    case .limitExceeded: "The CloudKit request was too large."
    }
  }
}

extension CloudKitZoneLoss {
  public var explanation: String {
    switch self {
    case .missing: "The vault's iCloud zone no longer exists."
    case .purged: "The app's iCloud data was deleted in Settings."
    case .encryptedDataReset: "The iCloud account's encrypted data was reset."
    }
  }
}
