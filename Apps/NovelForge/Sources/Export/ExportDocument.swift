import SwiftUI
import UniformTypeIdentifiers

struct ExportDocument: FileDocument {
  static let novelPackage = UTType(exportedAs: "com.shadow.apps.novelforge.novel", conformingTo: .zip)
  static let markdown = UTType("net.daringfireball.markdown") ?? .plainText
  static var readableContentTypes: [UTType] { [] }
  static var writableContentTypes: [UTType] { [markdown, novelPackage] }

  let data: Data

  init(data: Data = Data()) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    throw CocoaError(.fileReadUnsupportedScheme)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
