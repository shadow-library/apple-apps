import CryptoKit
import Foundation

public enum BlobName {
  static let keyInfo = Data("SLV1/blob-name".utf8)

  public static func make(for content: Data, key: VaultKey) -> String {
    let nameKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key.symmetricKey, salt: Data(), info: keyInfo, outputByteCount: 32)
    return lowercaseHex(HMAC<SHA256>.authenticationCode(for: content, using: nameKey))
  }
}

public enum ContentHash {
  public static func hex(of data: Data, length: Int = 16) -> String {
    String(lowercaseHex(SHA256.hash(data: data)).prefix(max(0, length)))
  }
}

private let hexDigits = Array("0123456789abcdef".utf8)

func lowercaseHex(_ bytes: some Sequence<UInt8>) -> String {
  var characters: [UInt8] = []
  for byte in bytes {
    characters.append(hexDigits[Int(byte >> 4)])
    characters.append(hexDigits[Int(byte & 0x0F)])
  }
  return String(decoding: characters, as: UTF8.self)
}
