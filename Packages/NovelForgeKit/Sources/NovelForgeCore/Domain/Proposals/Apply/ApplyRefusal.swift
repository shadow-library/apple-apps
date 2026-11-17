import ShadowCore

// apps/novel-forge-server/src/classes/app-error-code.ts:168-197: an op a handler refuses before its first write
enum ApplyRefusal: ShadowError, Equatable {
  case locked
  case isolated
  case overlapping(chapter: Int)
  case stale(passage: String, chapter: Int)
  case notAllowed
  case malformedInverse
  case unsettledWorkingCopy(chapter: Int)
  case lastAdvancedAhead(chapter: Int, latest: Int)
  case lastAdvancedUntracked
  case unreadableReferences(kind: String, count: Int)

  var code: String {
    switch self {
    case .locked: "RFN_010"
    case .isolated: "RFN_012"
    case .overlapping: "RFN_020"
    case .stale: "RFN_021"
    case .notAllowed: "RFN_004"
    case .malformedInverse: "refinement.malformed_inverse"
    case .unsettledWorkingCopy: "refinement.unsettled_working_copy"
    // app-error-code.ts:218
    case .lastAdvancedAhead: "PMS_003"
    case .lastAdvancedUntracked: "refinement.last_advanced_untracked"
    case .unreadableReferences: "refinement.unreadable_references"
    }
  }

  var errorDescription: String? {
    switch self {
    case .locked: "Draft is final or the chapter is already finalized — prose cannot be modified"
    case .isolated: "This chapter is isolated — chat cannot see its prose, so it cannot rewrite it. Edit the prose in the chapter editor."
    case .overlapping(let chapter): "Two of the selected rewrites change the same words of chapter \(chapter) — select only one of them"
    case .stale(let passage, let chapter): "The rewrite of \(passage) in chapter \(chapter) no longer matches the chapter — uncheck it to apply the others, or ask again"
    case .notAllowed: "Change-set operation not allowed for this scope"
    case .malformedInverse: "The stored undo of this change cannot be read, so it is not undone"
    case .unsettledWorkingCopy(let chapter): "Chapter \(chapter) has unsaved edits on this device — save or close the chapter, then apply the change again"
    case .lastAdvancedAhead(let chapter, let latest): "lastAdvancedChapter (\(chapter)) cannot be ahead of the latest chapter (\(latest))"
    case .lastAdvancedUntracked: "This version does not record the chapter a promise last advanced in, so the change is not applied"
    case .unreadableReferences(let kind, let count): "\(count) \(kind) records cannot be read on this device, so the change is not applied"
    }
  }
}
