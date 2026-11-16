import Foundation

public enum VaultFormat {
  public static let version: UInt8 = 1
  public static let magic = Data("SLV1".utf8)
}
