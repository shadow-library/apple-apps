import CryptoKit
import Foundation

public struct VaultKey: Sendable {
  public static let byteCount = 32

  public let id: KeyID
  let symmetricKey: SymmetricKey

  public init?(id: KeyID, rawBytes: Data) {
    guard rawBytes.count == Self.byteCount else { return nil }
    self.id = id
    symmetricKey = SymmetricKey(data: rawBytes)
  }

  private init(id: KeyID, symmetricKey: SymmetricKey) {
    self.id = id
    self.symmetricKey = symmetricKey
  }

  public static func generate(id: KeyID) -> VaultKey {
    VaultKey(id: id, symmetricKey: SymmetricKey(size: .bits256))
  }

  public var rawBytes: Data {
    symmetricKey.withUnsafeBytes { Data($0) }
  }
}

extension VaultKey: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(self, children: ["id": id], displayStyle: .struct)
  }
}
