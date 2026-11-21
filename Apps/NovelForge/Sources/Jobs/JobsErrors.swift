import Foundation
import NovelForgeCore
import ShadowCore
import ShadowJobs
import ShadowStore

/// Headlines for the codes a job's start, cancel or end surfaces; a code with no headline gets the generic words, so a new code reads as vague, not wrong.
enum JobsErrors {
  static func presented(_ error: JobEngineError) -> PresentedError {
    switch error {
    case .store(let store), .record(.store(let store)), .run(.store(let store)), .run(.record(.store(let store))): PresentedError(store)
    default: PresentedError(headline: headline(code: error.code) ?? generic, detail: error.code)
    }
  }

  static func presented(_ error: DomainError) -> PresentedError {
    PresentedError(error) { headline(code: $0.code) }
  }

  /// What an attempt that ended failed says, by its stored code.
  static func failure(_ failure: AttemptFailure?) -> String {
    failure.flatMap { headline(code: $0.code) } ?? String(localized: "The job didn't finish.", table: "Jobs")
  }

  static var notRunningHere: PresentedError {
    PresentedError(headline: String(localized: "Jobs aren't running in this copy of Novel Forge.", table: "Jobs"), detail: nil)
  }

  /// Run here or Resume refused for another device's live run names that device, as the replica directory names it, when it can.
  static func presented(_ error: JobEngineError, holder device: String?) -> PresentedError {
    guard case .runningElsewhere = error, let device else { return presented(error) }
    return PresentedError(headline: String(localized: "\(device) is running this job now. It goes on there.", table: "Jobs"), detail: error.code)
  }

  static var readNeedsApproval: PresentedError {
    PresentedError(headline: String(localized: "This chapter has no approved version to read. Approve it again.", table: "Jobs"), detail: nil)
  }

  // apps/novel-forge-server/src/classes/app-error-code.ts:20-66, 296-309 for the domain codes
  static func headline(code: String) -> String? {
    switch code {
    case "DRF_003": String(localized: "Another chapter has an unresolved contradiction. Repair or regenerate it first.", table: "Jobs")
    case "DRF_010": String(localized: "A chapter of this novel is already being written. Wait for it to finish, or stop it.", table: "Jobs")
    case "DRF_019": String(localized: "This chapter is being written. Wait for it to finish, or stop it.", table: "Jobs")
    case "PLN_009": String(localized: "A plan for this chapter is already being made. Wait for it, or cancel it.", table: "Jobs")
    case "JOB_002":
      String(localized: "A chapter of this novel is being written, planned or finalized. Wait for it to finish or cancel it, then try again.", table: "Jobs")
    case "FRV_002": String(localized: "The Story Bible updates are still being read from the approved version. Try again in a moment.", table: "Jobs")
    case "FRV_003": String(localized: "Reading the Story Bible updates from this chapter failed. Read them again.", table: "Jobs")
    case "AI_024": String(localized: "Unrestricted writing isn't available right now.", table: "Jobs")
    case "AI_015": String(localized: "The model's answer crossed a hard line, so nothing it wrote was kept.", table: "Jobs")
    case "job_engine.held_by_another_process": String(localized: "Another copy of Novel Forge is running this library's jobs.", table: "Jobs")
    case "job_engine.running_elsewhere", "job_run.another_attempt_live": String(localized: "Another device is running this job.", table: "Jobs")
    case "job_engine.nothing_to_resume": String(localized: "This device has nothing left of this run to resume. Run it again instead.", table: "Jobs")
    case "job_engine.job_not_found", "job_run.job_unreadable": String(localized: "This job hasn't arrived on this device yet.", table: "Jobs")
    case "job_engine.pipeline_not_yet_available", "job_engine.not_a_novel_job": String(localized: "This version of Novel Forge can't run this job yet.", table: "Jobs")
    case "job_engine.pipeline_changed": String(localized: "This job was started by another version of Novel Forge.", table: "Jobs")
    case "job_run.job_cancelled": String(localized: "This job was cancelled.", table: "Jobs")
    case "job_run.job_succeeded": String(localized: "This job has already finished.", table: "Jobs")
    case "job_run.interrupted", "job_run.checkpoint_unreadable": String(localized: "The job was interrupted when the app closed.", table: "Jobs")
    case "routing.credential_missing": String(localized: "No AI key is set up. Add your key in AI settings.", table: "Jobs")
    case "routing.consent_required": String(localized: "Novel Forge needs your permission before it sends this chapter.", table: "Jobs")
    case "routing.daily_spend_limit", "routing.monthly_spend_limit": String(localized: "AI spending limit reached.", table: "Jobs")
    case "model.authentication", "model.forbidden": String(localized: "The provider did not accept your key.", table: "Jobs")
    case "model.rate_limited", "model.overloaded": String(localized: "Too many model calls right now. Wait a moment, then try again.", table: "Jobs")
    case "model.transport", "model.server", "model.mid_stream": String(localized: "Couldn't reach the model. Try again shortly.", table: "Jobs")
    default: nil
    }
  }

  private static var generic: String { String(localized: "Something went wrong.", table: "Jobs") }
}
