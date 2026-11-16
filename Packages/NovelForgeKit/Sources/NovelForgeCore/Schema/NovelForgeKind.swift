import ShadowStore

public enum NovelForgeKind: String, CaseIterable, Sendable {
  case novel = "nf_novel"
  case volume = "nf_volume"
  case milestone = "nf_milestone"
  case thread = "nf_thread"
  case mystery = "nf_mystery"
  case secret = "nf_secret"
  case entity = "nf_entity"
  case characterKnowledge = "nf_character_knowledge"
  case page = "nf_page"
  case chapterPlan = "nf_chapter_plan"
  case draft = "nf_draft"
  case approval = "nf_approval"
  case finalChapter = "nf_final_chapter"
  case notebookEntry = "nf_notebook_entry"
  case notebookWithdrawal = "nf_notebook_withdrawal"
  case authorNotes = "nf_author_notes"

  public var entityKind: EntityKind {
    guard let kind = EntityKind(rawValue) else { preconditionFailure("\(rawValue) is a valid entity kind") }
    return kind
  }

  public init?(_ kind: EntityKind) {
    guard let match = Self.allCases.first(where: { $0.rawValue.utf8.elementsEqual(kind.rawValue.utf8) }) else { return nil }
    self = match
  }
}
