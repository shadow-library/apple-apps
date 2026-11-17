import Foundation
import NovelForgeCore
import Observation

enum PageFormMode: Equatable {
  case create
  case edit(address: PageAddress, title: String, body: String, revision: String?)
}

@MainActor
@Observable
final class PageForm {
  let mode: PageFormMode
  var section = BiblePageSection.world
  var title: String
  var slug = ""
  var body: String
  private(set) var slugEdited = false
  private(set) var failure: PresentedError?
  private(set) var isSubmitting = false
  private var revision: String?

  init(mode: PageFormMode) {
    self.mode = mode
    switch mode {
    case .create:
      title = ""
      body = ""
    case .edit(_, let title, let body, let revision):
      self.title = title
      self.body = body
      self.revision = revision
    }
  }

  var isCreating: Bool { mode == .create }
  var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
  var resolvedSlug: String { slugEdited ? slug.trimmingCharacters(in: .whitespacesAndNewlines) : BibleKey.slug(from: title) }
  var suggestedSlug: String { BibleKey.slug(from: title) }

  var hasChanges: Bool {
    switch mode {
    case .create: !trimmedTitle.isEmpty || !body.isEmpty
    case .edit(_, let original, let text, _): trimmedTitle != original || body != text
    }
  }

  var canSubmit: Bool {
    guard !isSubmitting, hasChanges else { return false }
    return !isCreating || !resolvedSlug.isEmpty
  }

  var slugIssue: String? {
    guard isCreating, !title.isEmpty || slugEdited, resolvedSlug.isEmpty else { return nil }
    return String(localized: "Use at least one letter or digit.", table: "StoryBible")
  }

  func editSlug(_ text: String) {
    slugEdited = true
    slug = text
  }

  func edited() {
    failure = nil
  }

  func submit(using model: StoryBibleModel) async -> PageAddress? {
    guard canSubmit else { return nil }
    isSubmitting = true
    failure = nil
    defer { isSubmitting = false }
    do {
      switch mode {
      case .create:
        return try await model.createPage(section: section, title: title, slug: resolvedSlug, body: body)
      case .edit(let address, _, _, _):
        _ = try await model.savePage(address, title: title, body: body, basedOn: revision)
        return address
      }
    } catch {
      if let issue = error as? BibleWriteIssue, case .pageChanged(let head) = issue { revision = head }
      failure = StoryBibleErrors.presented(error)
      return nil
    }
  }
}
