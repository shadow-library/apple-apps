import Foundation
import ShadowSync

/// Graph paths relative to the API version root. Files are addressed by path under the app folder, so a recreated vault folder needs no cached id.
struct OneDrivePaths: Sendable {
  static let appFolderChildren = "/me/drive/special/approot/children"
  static let batch = "/$batch"

  let folder: String

  init(vault: VaultFolderName) {
    folder = "/me/drive/special/approot:/" + Self.escaped(vault.rawValue)
  }

  func item(_ name: String) -> String {
    folder + "/" + Self.escaped(name)
  }

  func content(_ name: String) -> String {
    item(name) + ":/content"
  }

  func uploadSession(_ name: String) -> String {
    item(name) + ":/createUploadSession"
  }

  static func delta(folderID: String) -> String {
    "/me/drive/items/" + escaped(folderID) + "/delta"
  }

  static func content(itemID: String) -> String {
    "/me/drive/items/" + escaped(itemID) + "/content"
  }

  private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  static func escaped(_ segment: String) -> String {
    segment.addingPercentEncoding(withAllowedCharacters: unreserved) ?? segment
  }
}
