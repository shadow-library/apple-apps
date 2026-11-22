import Foundation
import NovelForgeCore
import Observation
import ShadowAppShell
import ShadowStore

@MainActor
@Observable
final class AmendModel {
  enum Phase: Equatable {
    case editing
    case saving
    case amended
    case failed(PresentedError)
  }

  let chapter: Int
  var body: String
  var title: String
  var note = ""
  private(set) var phase = Phase.editing
  @ObservationIgnored private let context: NovelContext
  @ObservationIgnored private let original: ChapterContent.Final

  init(context: NovelContext, chapter: Int, final: ChapterContent.Final) {
    self.context = context
    self.chapter = chapter
    original = final
    body = final.body
    title = final.title ?? ""
  }

  var isSaving: Bool { phase == .saving }
  var isAmended: Bool { phase == .amended }
  var canAmend: Bool { !body.allSatisfy(\.isWhitespace) && phase != .saving && phase != .amended }
  var hasChanges: Bool { phase != .amended && (body != original.body || title != (original.title ?? "") || !note.isEmpty) }

  var amendment: ChapterAmendment {
    ChapterAmendment(content: body, title: Self.trimmed(title), note: Self.trimmed(note))
  }

  func amend() async {
    guard canAmend else { return }
    phase = .saving
    let (store, novel, chapter, amendment) = (context.store, context.novel, chapter, amendment)
    do {
      try await store.writeDomain { transaction throws(DomainError) in try FinalChapters.amend(novel: novel, chapter: chapter, amendment, in: &transaction) }
      phase = .amended
    } catch {
      phase = .failed(AmendErrors.presented(error))
    }
  }

  func dismissFailure() {
    if case .failed = phase { phase = .editing }
  }

  private static func trimmed(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
