import Foundation
import ShadowAI
import ShadowCore

enum ChapterCallError: ShadowError {
  /// The plan head names a content mode this version cannot read, so the chapter's route is unknown and nothing is sent.
  case unknownContentMode(String)
  /// The chapter must be written unrestricted and this build cannot; it is never downgraded to standard.
  case unrestrictedUnavailable
  case routing(TaskRouterError)
  /// The router's route did not keep the chapter's mode, or an unrestricted route carried no hard-line guard; nothing was sent.
  case routeMismatch(ModelContentMode)
  case hardLine(HardLineHit)
  case model(StructuredError)

  var code: String {
    switch self {
    case .unknownContentMode: "chapter_call.unknown_content_mode"
    case .unrestrictedUnavailable: "AI_024"
    case .routing(let error): error.code
    case .routeMismatch: "chapter_call.route_mismatch"
    case .hardLine: "AI_015"
    case .model(let error): error.code
    }
  }

  var errorDescription: String? {
    switch self {
    case .unknownContentMode: "This chapter's content mode was set by a newer version of Novel Forge, so it can't be written here."
    case .unrestrictedUnavailable: "Unrestricted writing isn't available in this version."
    case .routing(let error): error.errorDescription
    case .routeMismatch: "The model route didn't keep this chapter's content mode and hard line, so nothing was sent."
    case .hardLine(let hit): hardLineError(hit).errorDescription
    case .model(let error): error.errorDescription
    }
  }
}

/// `callIDs` are the ledger ids of the requests the failed call made, so an attempt can attribute their spend.
struct ChapterCallFailure: ShadowError {
  let error: ChapterCallError
  let callIDs: [UUID]

  var code: String { error.code }

  var errorDescription: String? { error.errorDescription }
}
