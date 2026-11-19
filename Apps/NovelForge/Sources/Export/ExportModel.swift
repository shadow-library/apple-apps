import Foundation
import NovelForgeCore
import Observation
import ShadowStore
import UniformTypeIdentifiers

@MainActor
@Observable
final class ExportModel {
  enum Kind: Equatable {
    case manuscript
    case package
  }

  struct Prepared: Equatable {
    let document: ExportDocument
    let type: UTType
    let filename: String
  }

  var isExporting = false
  private(set) var prepared: Prepared?
  private(set) var isPreparing = false
  private(set) var failure: PresentedError?
  @ObservationIgnored private let context: NovelContext

  init(context: NovelContext) {
    self.context = context
  }

  func prepare(_ kind: Kind, title: String) async {
    guard !isPreparing else { return }
    isPreparing = true
    defer { isPreparing = false }
    do {
      prepared = try await build(kind, title: title)
      isExporting = true
    } catch {
      failure = ExportErrors.presented(error)
    }
  }

  func finish() {
    isExporting = false
    prepared = nil
  }

  func dismissFailure() { failure = nil }

  private func build(_ kind: Kind, title: String) async throws(ExportError) -> Prepared {
    switch kind {
    case .manuscript:
      let text = try await context.store.exportManuscript(novel: context.novel)
      return Prepared(document: ExportDocument(data: Data(text.utf8)), type: ExportDocument.markdown, filename: Self.filename(title, extension: "md"))
    case .package:
      let package = try await context.store.exportPackage(novel: context.novel)
      return Prepared(document: ExportDocument(data: package.bytes), type: ExportDocument.novelPackage, filename: package.filename)
    }
  }

  nonisolated static func filename(_ title: String, extension pathExtension: String) -> String {
    let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)).joined(separator: " ")
    let name = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return "\(name.isEmpty ? "Novel" : name).\(pathExtension)"
  }
}

extension ExportDocument: Equatable {
  static func == (left: ExportDocument, right: ExportDocument) -> Bool { left.data == right.data }
}
