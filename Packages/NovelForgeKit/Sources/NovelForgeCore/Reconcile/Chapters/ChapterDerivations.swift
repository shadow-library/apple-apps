public enum ChapterDerivations {
  public static let all: [any Derivation] = [
    FinalChapterDerivation(),
    StoryCursorDerivation(),
    ChapterDraftDerivation(),
    ChapterApprovalDerivation(),
    ChapterReviewDerivation(),
    ChapterLifecycleDerivation(),
    ApprovalInForceDerivation(),
    CharacterKnowledgeDerivation(),
    ReaderDisclosureDerivation(),
    ChapterHeadingSourceDerivation(),
    ChapterHeadingDerivation(),
  ]
}
