import CryptoKit
import Foundation
import ShadowCore
import ShadowStore

struct BlobPartHeader: Sendable, Equatable {
  let blob: BlobID
  let syncClass: SyncClass
  let digest: String
  let size: Int
  let part: Int
  let parts: Int
  let offset: Int
  let length: Int

  func belongs(with other: BlobPartHeader) -> Bool {
    blob == other.blob && syncClass == other.syncClass && digest == other.digest && size == other.size && parts == other.parts
  }
}

/// A part is a vault file whose plaintext is the stored codec byte, one canonical JSON header line and the part's bytes; it is sealed and opened a chunk at a
/// time, so a part is never held in memory both sealed and in plain.
enum BlobCodec {
  static let kind = "com.shadow.library.shadowsync.blob"
  static let members: Set<String> = ["blob", "class", "digest", "format", "kind", "length", "offset", "part", "parts", "size"]
  static let maximumHeaderBytes = 512
  static let digestLength = 64
  static let readChunk = 1 << 20

  static func digest(of data: Data) -> String {
    lowercaseHex(SHA256.hash(data: data))
  }

  /// Part ranges no larger than `partBytes` whose sealed parts each fit `limit`.
  static func layout(size: Int, partBytes: Int, limit: Int, vault: VaultID) -> [Range<Int>]? {
    var payload = max(1, partBytes)
    while sealedLength(payload: payload, vault: vault) > limit {
      let next = min(payload - 1, payload - (sealedLength(payload: payload, vault: vault) - limit))
      guard next >= 1 else { return nil }
      payload = next
    }
    let count = max(1, (size + payload - 1) / payload)
    guard count <= VaultPath.maximumParts else { return nil }
    return (0..<count).map { index in (index * payload)..<min(size, (index + 1) * payload) }
  }

  static func sealedLength(payload: Int, vault: VaultID) -> Int {
    let body = 2 + maximumHeaderBytes + payload
    let chunks = max(1, (body + VaultFile.defaultChunkSize - 1) / VaultFile.defaultChunkSize)
    return VaultFile.fixedHeaderLength + vault.rawValue.utf8.count + body + chunks * VaultFile.tagSize
  }

  static func seal(_ header: BlobPartHeader, from file: FileHandle, vault: VaultID, key: VaultKey) throws(BlobError) -> Data {
    let objectKey = VaultPath.blobPart(name: header.blob.description, part: header.part, parts: header.parts)
    let line = CanonicalJSON.encode(value(of: header))
    guard line.count <= maximumHeaderBytes else { throw .corrupt(header.blob, reason: "the part header is too long") }
    do {
      var sealer = try VaultFileSealer(path: objectKey.rawValue, vault: vault, key: key)
      var output = sealer.header
      output.reserveCapacity(sealedLength(payload: header.length, vault: vault))
      var chunk = Data([CodecFrame.storedCodec]) + line + Data([CodecFrame.newline])
      try file.seek(toOffset: UInt64(header.offset))
      var remaining = header.length
      while true {
        let wanted = min(sealer.chunkSize - chunk.count, remaining)
        if wanted > 0 {
          guard let read = try file.read(upToCount: wanted), read.count == wanted else { throw BlobError.file("the local copy of \(header.blob) is shorter than recorded") }
          chunk.append(read)
          remaining -= wanted
        }
        let isFinal = remaining == 0
        guard isFinal || chunk.count == sealer.chunkSize else { continue }
        output.append(try sealer.seal(chunk: chunk, isFinal: isFinal))
        chunk.removeAll(keepingCapacity: true)
        if isFinal { return output }
      }
    } catch let error as BlobError {
      throw error
    } catch {
      throw .file(error.localizedDescription)
    }
  }

  /// Hands the part's bytes to `sink` as each chunk authenticates; they are trustworthy only once this returns.
  static func open(
    _ sealed: Data, at key: ObjectKey, vault: VaultID, keys: (KeyID) -> VaultKey?, sink: (Data) throws(BlobError) -> Void
  ) throws(BlobError) -> BlobPartHeader {
    guard case .blobPart(let name, let part, let parts) = VaultPath.classify(key), let id = BlobID(name) else { throw .file("\(key) is not a blob part") }
    var reader = PartReader(id: id)
    do {
      let fileHeader = try VaultFileHeader.parse(sealed)
      let headerEnd = sealed.startIndex + fileHeader.encodedLength
      var opener = try VaultFileOpener(header: sealed[sealed.startIndex..<headerEnd], path: key.rawValue, vault: vault, keys: keys)
      let sealedChunkSize = opener.sealedChunkSize
      var start = headerEnd
      while sealed.endIndex - start > sealedChunkSize {
        try reader.consume(try opener.open(chunk: sealed[start..<(start + sealedChunkSize)], isFinal: false), sink: sink)
        start += sealedChunkSize
      }
      guard sealed.endIndex - start >= VaultFile.tagSize else { throw VaultFileError.truncated }
      try reader.consume(try opener.open(chunk: sealed[start...], isFinal: true), sink: sink)
      try opener.finish()
    } catch let error as VaultFileError {
      guard case .keyUnavailable(let keyID) = error else { throw .corrupt(id, reason: error.errorDescription ?? error.code) }
      throw .keyUnavailable(id, keyID)
    } catch let error as BlobError {
      throw error
    } catch {
      throw .corrupt(id, reason: error.localizedDescription)
    }
    guard let header = reader.header, reader.delivered == header.length else { throw .corrupt(id, reason: "the part is shorter than its header says") }
    guard header.part == part, header.parts == parts else { throw .corrupt(id, reason: "the part header does not match its name") }
    return header
  }

  private struct PartReader {
    let id: BlobID
    var prefix = Data()
    var header: BlobPartHeader?
    var delivered = 0

    mutating func consume(_ plaintext: Data, sink: (Data) throws(BlobError) -> Void) throws(BlobError) {
      guard header == nil else { return try deliver(plaintext, sink: sink) }
      prefix.append(plaintext)
      guard let newline = prefix.dropFirst().firstIndex(of: CodecFrame.newline) else {
        guard prefix.count <= 1 + maximumHeaderBytes else { throw .corrupt(id, reason: "no part header") }
        return
      }
      guard prefix.first == CodecFrame.storedCodec else { throw .corrupt(id, reason: "unsupported codec") }
      let parsed = try BlobCodec.parse(Data(prefix[(prefix.startIndex + 1)..<newline]), id: id)
      header = parsed
      let rest = Data(prefix[(newline + 1)...])
      prefix = Data()
      try deliver(rest, sink: sink)
    }

    private mutating func deliver(_ bytes: Data, sink: (Data) throws(BlobError) -> Void) throws(BlobError) {
      guard let header, !bytes.isEmpty else { return }
      guard bytes.count <= header.length - delivered else { throw .corrupt(id, reason: "the part is longer than its header says") }
      delivered += bytes.count
      try sink(bytes)
    }
  }

  private static func value(of header: BlobPartHeader) -> JSONValue {
    .object([
      "blob": .string(header.blob.description),
      "class": .string(header.syncClass.rawValue),
      "digest": .string(header.digest),
      "format": .int(CodecFrame.format),
      "kind": .string(kind),
      "length": .int(Int64(header.length)),
      "offset": .int(Int64(header.offset)),
      "part": .int(Int64(header.part)),
      "parts": .int(Int64(header.parts)),
      "size": .int(Int64(header.size)),
    ])
  }

  private static func parse(_ line: Data, id: BlobID) throws(BlobError) -> BlobPartHeader {
    do throws(VaultCodecError) {
      let fields = try CodecFields(line: line, kind: kind, members: members)
      guard let blob = BlobID(try fields.string("blob")), blob == id else { throw VaultCodecError.malformed("the header names another blob") }
      guard let syncClass = SyncClass(rawValue: try fields.string("class")) else { throw VaultCodecError.malformed("the sync class is unknown") }
      let digest = try fields.string("digest")
      guard CodecText.isLowerHex(digest, count: digestLength) else { throw VaultCodecError.malformed("the digest is malformed") }
      let header = BlobPartHeader(
        blob: blob, syncClass: syncClass, digest: digest, size: try fields.count("size"), part: try fields.count("part"), parts: try fields.count("parts"),
        offset: try fields.count("offset"), length: try fields.count("length"))
      guard VaultPath.isPart(header.part, of: header.parts), header.offset <= header.size, header.length <= header.size - header.offset else {
        throw VaultCodecError.malformed("the part does not fit the blob")
      }
      return header
    } catch {
      throw .corrupt(id, reason: error.errorDescription ?? error.code)
    }
  }
}
