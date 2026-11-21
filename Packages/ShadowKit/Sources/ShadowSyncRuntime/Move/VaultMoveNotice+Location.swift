import Foundation
import ShadowCore
import ShadowSync

extension VaultMoveNotice {
  /// The new location as the mover saved it, without its account binding or a local folder's bookmark: neither means anything on another device.
  public var targetLocation: SyncLocation? {
    try? JSONDecoder().decode(SyncLocation.self, from: CanonicalJSON.encode(.object(target)))
  }

  static func target(of location: SyncLocation) -> [String: JSONValue] {
    let settings: SyncProviderSettings =
      switch location.settings {
      case .localFolder(let folder): .localFolder(SyncLocalFolderSettings(url: folder.url))
      default: location.settings
      }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(SyncLocation(settings: settings, vault: location.vault, account: nil)),
      case .object(let members) = try? CanonicalJSON.decode(data, mode: .lenient)
    else { preconditionFailure("a sync location encodes as a JSON object") }
    return members
  }
}
