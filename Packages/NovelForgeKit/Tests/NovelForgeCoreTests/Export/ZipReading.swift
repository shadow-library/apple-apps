import Foundation

@testable import NovelForgeCore

struct ZipReadFailure: Error, Equatable {
  let reason: String
}

enum ZipReading {
  static func entries(_ archive: Data) throws -> [ZipEntry] {
    let bytes = [UInt8](archive)
    guard bytes.count >= 22 else { throw ZipReadFailure(reason: "shorter than an end record") }
    let end = bytes.count - 22
    guard u32(bytes, end) == 0x0605_4B50, u16(bytes, end + 20) == 0 else { throw ZipReadFailure(reason: "no end record at the end") }
    let count = Int(u16(bytes, end + 10))
    guard Int(u16(bytes, end + 8)) == count, u16(bytes, end + 4) == 0, u16(bytes, end + 6) == 0 else { throw ZipReadFailure(reason: "split archive") }
    let directoryBytes = Int(u32(bytes, end + 12))
    var cursor = Int(u32(bytes, end + 16))
    guard cursor + directoryBytes == end else { throw ZipReadFailure(reason: "directory does not end at the end record") }

    var entries = [ZipEntry]()
    for _ in 0..<count {
      guard u32(bytes, cursor) == 0x0201_4B50 else { throw ZipReadFailure(reason: "bad central signature") }
      guard u16(bytes, cursor + 8) == 0x0800, u16(bytes, cursor + 10) == 0 else { throw ZipReadFailure(reason: "not a stored UTF-8 entry") }
      guard u16(bytes, cursor + 12) == 0, u16(bytes, cursor + 14) == 0x0021 else { throw ZipReadFailure(reason: "not the DOS epoch") }
      let checksum = u32(bytes, cursor + 16)
      let size = Int(u32(bytes, cursor + 24))
      guard Int(u32(bytes, cursor + 20)) == size else { throw ZipReadFailure(reason: "stored sizes differ") }
      let nameLength = Int(u16(bytes, cursor + 28))
      let local = Int(u32(bytes, cursor + 42))
      let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)

      guard u32(bytes, local) == 0x0403_4B50, u16(bytes, local + 6) == 0x0800, u16(bytes, local + 8) == 0, u32(bytes, local + 14) == checksum,
        Int(u32(bytes, local + 18)) == size, Int(u32(bytes, local + 22)) == size, Int(u16(bytes, local + 26)) == nameLength, u16(bytes, local + 28) == 0
      else { throw ZipReadFailure(reason: "local header of \(name) disagrees with the directory") }
      let start = local + 30 + nameLength
      guard start + size <= bytes.count else { throw ZipReadFailure(reason: "data of \(name) runs past the archive") }
      let data = Data(bytes[start..<(start + size)])
      guard CRC32.checksum(data) == checksum else { throw ZipReadFailure(reason: "checksum of \(name) is wrong") }
      entries.append(ZipEntry(name: name, data: data))
      cursor += 46 + nameLength
    }
    guard cursor == end else { throw ZipReadFailure(reason: "directory has trailing bytes") }
    return entries
  }

  private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(u16(bytes, offset)) | UInt32(u16(bytes, offset + 2)) << 16
  }
}
