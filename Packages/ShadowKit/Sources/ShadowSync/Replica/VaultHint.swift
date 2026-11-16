import Foundation
import ShadowCore

public struct VaultHint: Sendable, Equatable {
  public static let currentFormat = 1
  public static let maximumBytes = 4096
  private static let members: Set<String> = ["format", "vault"]

  public let format: Int
  public let vault: VaultID

  public init(vault: VaultID) {
    format = Self.currentFormat
    self.vault = vault
  }

  public init(decoding data: Data) throws(ReplicaFileError) {
    guard data.count <= Self.maximumBytes else { throw .tooLarge }
    let members = try ReplicaJSON.object(data)
    try ReplicaJSON.requireFormat(members, current: Int64(Self.currentFormat))
    guard Set(members.keys) == Self.members else { throw .malformed("hint members differ") }
    guard case .string(let text)? = members["vault"], let vault = VaultID(text) else { throw .malformed("vault is not a vault id") }
    self.init(vault: vault)
  }

  public func encoded() -> Data {
    CanonicalJSON.encode(.object(["format": .int(Int64(format)), "vault": .string(vault.rawValue)]))
  }
}
