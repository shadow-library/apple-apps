import Foundation

enum DraftFileError: Error, Equatable {
  case unreadable
  case notText
  case unsupportedEncoding
  case empty
  case tooLarge
}

nonisolated enum DraftFile {
  static let maximumBytes = 2_000_000

  static func read(from url: URL) throws(DraftFileError) -> String {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let data: Data
    do {
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= maximumBytes else { throw DraftFileError.tooLarge }
      data = try Data(contentsOf: url)
    } catch let error as DraftFileError {
      throw error
    } catch {
      throw .unreadable
    }
    guard data.count <= maximumBytes else { throw .tooLarge }
    let text = try decode(data)
    guard !text.allSatisfy(\.isWhitespace) else { throw .empty }
    return text
  }

  static func decode(_ data: Data) throws(DraftFileError) -> String {
    if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { throw .unsupportedEncoding }
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
      guard let text = String(data: data, encoding: .utf16) else { throw .unsupportedEncoding }
      return text
    }
    let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
    guard !bytes.contains(0) else { throw .notText }
    guard let text = String(data: bytes, encoding: .utf8) else { throw .unsupportedEncoding }
    return text
  }
}
