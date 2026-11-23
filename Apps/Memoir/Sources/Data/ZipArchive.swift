import Compression
import Foundation

nonisolated enum ZipArchiveError: Error, Equatable {
  case unreadable(String)
  case tooLarge
  case unsupported(String)
  case damaged(String)
}

/// A zip archive read in place, for restoring an export: only its central directory is trusted for names and sizes, nothing is extracted by name onto
/// disk, and an entry is read only when asked for, bounded by its declared size and checked against its CRC-32. Stored and deflated entries are read;
/// zip64, encryption, multi-disk archives and duplicate names are refused, and a symbolic link is listed as one so a caller can refuse it.
nonisolated struct ZipArchive {
  struct Entry: Equatable {
    let name: String
    let method: UInt16
    let crc: UInt32
    let compressedSize: Int
    let size: Int
    let localHeaderOffset: Int
    let isSymbolicLink: Bool

    var isDirectory: Bool { name.hasSuffix("/") }
  }

  private static let endSignature: UInt32 = 0x0605_4b50
  private static let centralSignature: UInt32 = 0x0201_4b50
  private static let localSignature: UInt32 = 0x0403_4b50
  private static let endRecordBytes = 22
  private static let maximumCommentBytes = 0xFFFF
  private static let maximumNameBytes = 1024
  private static let stored: UInt16 = 0
  private static let deflated: UInt16 = 8

  let entries: [String: Entry]
  private let data: Data

  init(contentsOf url: URL, maximumBytes: Int, maximumEntries: Int) throws(ZipArchiveError) {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values?.isRegularFile == true, let size = values?.fileSize else { throw .unreadable("not a regular file") }
    guard size <= maximumBytes else { throw .tooLarge }
    do {
      try self.init(Data(contentsOf: url, options: .alwaysMapped), maximumEntries: maximumEntries)
    } catch let error as ZipArchiveError {
      throw error
    } catch {
      throw .unreadable(error.localizedDescription)
    }
  }

  init(_ data: Data, maximumEntries: Int) throws(ZipArchiveError) {
    self.data = data
    let end = try Self.endRecord(in: data)
    guard data.uint16(at: end + 4) == 0, data.uint16(at: end + 6) == 0 else { throw .unsupported("an archive split across disks") }
    guard let count = data.uint16(at: end + 10), let directorySize = data.uint32(at: end + 12), let directoryOffset = data.uint32(at: end + 16) else {
      throw .damaged("the end record is cut short")
    }
    guard count != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else { throw .unsupported("zip64") }
    guard Int(count) <= maximumEntries else { throw .tooLarge }
    guard Int(directoryOffset) + Int(directorySize) <= end else { throw .damaged("the central directory lies outside the archive") }
    var entries = [String: Entry]()
    var offset = Int(directoryOffset)
    for _ in 0..<count {
      let (entry, next) = try Self.centralEntry(in: data, at: offset)
      guard entries[entry.name] == nil else { throw .damaged("an entry name is listed twice") }
      entries[entry.name] = entry
      offset = next
    }
    self.entries = entries
  }

  /// Refuses an entry larger than `maximumBytes`, or whose compressed form is larger than any deflate of that size, before reading any of it.
  func contents(of entry: Entry, maximumBytes: Int) throws(ZipArchiveError) -> Data {
    guard entry.size <= maximumBytes else { throw .tooLarge }
    switch entry.method {
    case Self.stored: guard entry.compressedSize == entry.size else { throw .damaged("\(entry.name) is stored at a size it does not have") }
    case Self.deflated: guard entry.compressedSize <= Self.deflateBound(entry.size) else { throw .damaged("\(entry.name) is larger compressed than deflate makes it") }
    default: throw .unsupported("compression method \(entry.method)")
    }
    let start = entry.localHeaderOffset
    guard data.uint32(at: start) == Self.localSignature, let nameLength = data.uint16(at: start + 26), let extraLength = data.uint16(at: start + 28) else {
      throw .damaged("\(entry.name) has no local header")
    }
    let body = start + 30 + Int(nameLength) + Int(extraLength)
    guard body + entry.compressedSize <= data.count else { throw .damaged("\(entry.name) runs past the archive") }
    let range = (data.startIndex + body)..<(data.startIndex + body + entry.compressedSize)
    let contents = entry.method == Self.stored ? data.subdata(in: range) : try Self.inflate(data[range], size: entry.size, name: entry.name)
    guard CRC32.checksum(contents) == entry.crc else { throw .damaged("\(entry.name) does not match its checksum") }
    return contents
  }

  /// zlib's `deflateBound`: stored blocks cost five bytes per 16 KiB at worst, plus the stream's own few bytes.
  private static func deflateBound(_ size: Int) -> Int {
    size + (size >> 12) + (size >> 14) + (size >> 25) + 13
  }

  private static func endRecord(in data: Data) throws(ZipArchiveError) -> Int {
    guard data.count >= endRecordBytes else { throw .unreadable("not a zip archive") }
    let lowest = max(0, data.count - endRecordBytes - maximumCommentBytes)
    var offset = data.count - endRecordBytes
    while offset >= lowest {
      if data.uint32(at: offset) == endSignature, let comment = data.uint16(at: offset + 20), offset + endRecordBytes + Int(comment) == data.count { return offset }
      offset -= 1
    }
    throw .unreadable("not a zip archive")
  }

  private static func centralEntry(in data: Data, at offset: Int) throws(ZipArchiveError) -> (Entry, next: Int) {
    guard data.uint32(at: offset) == centralSignature, let madeBy = data.uint16(at: offset + 4), let flags = data.uint16(at: offset + 8),
      let method = data.uint16(at: offset + 10), let crc = data.uint32(at: offset + 16), let compressedSize = data.uint32(at: offset + 20),
      let size = data.uint32(at: offset + 24), let nameLength = data.uint16(at: offset + 28), let extraLength = data.uint16(at: offset + 30),
      let commentLength = data.uint16(at: offset + 32), let attributes = data.uint32(at: offset + 38), let localOffset = data.uint32(at: offset + 42)
    else { throw .damaged("a central directory entry is cut short") }
    guard flags & 0x1 == 0 else { throw .unsupported("encryption") }
    guard compressedSize != 0xFFFF_FFFF, size != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else { throw .unsupported("zip64") }
    guard Int(nameLength) <= maximumNameBytes else { throw .damaged("an entry name is too long") }
    let nameStart = offset + 46
    guard nameStart + Int(nameLength) <= data.count, let name = String(validating: data.subdata(in: nameStart..<(nameStart + Int(nameLength))), as: UTF8.self)
    else { throw .damaged("an entry name is not UTF-8") }
    let unixMode = madeBy >> 8 == 3 ? attributes >> 16 : 0
    let entry = Entry(
      name: name, method: method, crc: crc, compressedSize: Int(compressedSize), size: Int(size), localHeaderOffset: Int(localOffset),
      isSymbolicLink: unixMode & 0o170000 == 0o120000)
    return (entry, nameStart + Int(nameLength) + Int(extraLength) + Int(commentLength))
  }

  /// Raw DEFLATE (RFC 1951), which the Compression framework calls zlib; output beyond the declared size is cut off, so the checksum then fails.
  private static func inflate(_ compressed: Data.SubSequence, size: Int, name: String) throws(ZipArchiveError) -> Data {
    guard size > 0 else { return Data() }
    var output = Data(count: size)
    let written = output.withUnsafeMutableBytes { destination in
      compressed.withUnsafeBytes { source in
        guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress, let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return compression_decode_buffer(destinationBase, size, sourceBase, compressed.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard written == size else { throw .damaged("\(name) does not inflate to its declared size") }
    return output
  }
}

nonisolated enum CRC32 {
  private static let table: [UInt32] = (0..<256).map { index in
    (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
  }

  static func checksum(_ data: Data) -> UInt32 {
    ~data.reduce(~UInt32(0)) { crc, byte in table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
  }
}

extension Data {
  nonisolated fileprivate func uint16(at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= count else { return nil }
    let base = startIndex + offset
    return UInt16(self[base]) | UInt16(self[base + 1]) << 8
  }

  nonisolated fileprivate func uint32(at offset: Int) -> UInt32? {
    guard let low = uint16(at: offset), let high = uint16(at: offset + 2) else { return nil }
    return UInt32(low) | UInt32(high) << 16
  }
}
