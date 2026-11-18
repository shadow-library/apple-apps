import Foundation

struct ZipEntry: Sendable, Equatable {
  let name: String
  let data: Data
}

struct ZipLimits: Sendable {
  var entries: Int
  var bytes: Int

  static let standard = ZipLimits(entries: Int(UInt16.max), bytes: Int(UInt32.max) - 1)
}

/// A zip without compression and without zip64: every entry stored (method 0) with names flagged as UTF-8 and the DOS epoch as its time, so equal input is equal bytes.
enum StoredZip {
  private static let localSignature: UInt32 = 0x0403_4B50
  private static let centralSignature: UInt32 = 0x0201_4B50
  private static let endSignature: UInt32 = 0x0605_4B50
  private static let version: UInt16 = 20
  private static let utf8Flag: UInt16 = 0x0800
  private static let dosTime: UInt16 = 0
  private static let dosDate: UInt16 = 0x0021
  private static let localHeaderBytes = 30
  private static let centralHeaderBytes = 46
  private static let endBytes = 22

  static func write(_ entries: [ZipEntry], limits: ZipLimits = .standard) throws(ExportError) -> Data {
    guard entries.count <= limits.entries else { throw .archiveTooManyEntries(count: entries.count) }
    let named = try entries.map { entry throws(ExportError) in (entry: entry, name: Array(entry.name.utf8)) }
    var seen = Set<[UInt8]>()
    var total = endBytes
    for (entry, name) in named {
      guard !name.isEmpty, name.count <= Int(UInt16.max) else { throw .archiveNameInvalid(entry.name) }
      guard seen.insert(name).inserted else { throw .archiveDuplicateName(entry.name) }
      guard entry.data.count <= limits.bytes else { throw .archiveEntryTooLarge(name: entry.name, bytes: entry.data.count) }
      total += localHeaderBytes + centralHeaderBytes + 2 * name.count + entry.data.count
      guard total <= limits.bytes else { throw .archiveTooLarge(bytes: total) }
    }

    var output = Data()
    output.reserveCapacity(total)
    var locals = [UInt32]()
    var checksums = [UInt32]()
    for (entry, name) in named {
      locals.append(UInt32(output.count))
      let checksum = CRC32.checksum(entry.data)
      checksums.append(checksum)
      output.put(localSignature)
      output.put(version)
      output.put(utf8Flag)
      output.put(UInt16(0))
      output.put(dosTime)
      output.put(dosDate)
      output.put(checksum)
      output.put(UInt32(entry.data.count))
      output.put(UInt32(entry.data.count))
      output.put(UInt16(name.count))
      output.put(UInt16(0))
      output.append(contentsOf: name)
      output.append(entry.data)
    }

    let directory = output.count
    for (index, (entry, name)) in named.enumerated() {
      output.put(centralSignature)
      output.put(version)
      output.put(version)
      output.put(utf8Flag)
      output.put(UInt16(0))
      output.put(dosTime)
      output.put(dosDate)
      output.put(checksums[index])
      output.put(UInt32(entry.data.count))
      output.put(UInt32(entry.data.count))
      output.put(UInt16(name.count))
      output.put(UInt16(0))
      output.put(UInt16(0))
      output.put(UInt16(0))
      output.put(UInt16(0))
      output.put(UInt32(0))
      output.put(locals[index])
      output.append(contentsOf: name)
    }

    let directorySize = output.count - directory
    output.put(endSignature)
    output.put(UInt16(0))
    output.put(UInt16(0))
    output.put(UInt16(named.count))
    output.put(UInt16(named.count))
    output.put(UInt32(directorySize))
    output.put(UInt32(directory))
    output.put(UInt16(0))
    return output
  }
}

enum CRC32 {
  private static let table: [UInt32] = (0..<256).map { index in
    (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
  }

  static func checksum(_ data: Data) -> UInt32 {
    ~data.reduce(UInt32.max) { crc, byte in table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
  }
}

extension Data {
  fileprivate mutating func put<Value: FixedWidthInteger>(_ value: Value) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
}
