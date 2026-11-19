import Foundation
import NovelForgeCore
import Observation
import ShadowCore
import ShadowStore

/// The author's writes for one chapter's approval and finalize review (apps/novel-forge-web/src/features/chapter-workspace/FinalizeReviewDialog.tsx:81-197 and
/// use-draft-approval.tsx): every answer waits for the one before it, so two answers never race on the same review, and each refusal is kept by the item it
/// concerns.
@MainActor
@Observable
final class FinalizeModel {
  enum Mode: Equatable {
    case edit
    case skip
  }

  /// An approval this model made and how many blocking findings it recorded as overridden (chapter-checks.ts:274-278).
  struct Approved: Equatable {
    let overridden: Int
  }

  enum Answer: Equatable {
    case keep
    case edit([String: JSONValue])
    case skip(reason: String)
  }

  let store: VaultStore
  let novel: UUID
  let chapter: Int
  private(set) var deciding = false
  private(set) var finalizing = false
  private(set) var approving = false
  var modes: [String: Mode] = [:]
  private(set) var problems: [String: PresentedError] = [:]
  var refusal: PresentedError?
  /// Set once this dialog's finalize made the chapter final.
  private(set) var finalized = false
  private(set) var approved: Approved?
  /// Open blocking findings the author has not confirmed: a judge review arrived after they were asked, so the core refused and asks again.
  var reconfirm: Int?

  init(store: VaultStore, novel: UUID, chapter: Int) {
    self.store = store
    self.novel = novel
    self.chapter = chapter
  }

  var isFormOpen: Bool { !modes.isEmpty }

  func setMode(_ mode: Mode?, for item: String) {
    modes[item] = mode
    problems[item] = nil
  }

  /// Approves `revision`, the text the author read, as written when it is out of date (ChapterWorkspace.tsx:156-172); the approval asks for the read of its
  /// Story Bible updates in its own write, and this device's job runtime starts it from its backlog. The core refuses to override more open blocking findings
  /// than the author confirmed, which asks them again with the new count.
  @discardableResult
  func approve(revision: String, stale: StaleCause?, overriding: FinalizeOffer.Confirmation = .none) async -> Bool {
    guard !approving else { return false }
    approving = true
    defer { approving = false }
    refusal = nil
    approved = nil
    reconfirm = nil
    let intent: ApprovalIntent = stale.map { .asWritten(seen: $0) } ?? .standard
    let confirmed: Int? =
      switch overriding {
      case .none: 0
      case .overriding(let count): count
      case .overridingUnknown: nil
      }
    do throws(DomainError) {
      let approval = try await store.approveChapter(novel: novel, chapter: chapter, revision: revision, as: intent, confirmedOverrides: confirmed)
      approved = Approved(overridden: approval.overridden)
      return true
    } catch .approvalOverridesUnconfirmed(_, let open) {
      reconfirm = open
      return false
    } catch {
      refusal = FinalizeErrors.presented(error)
      return false
    }
  }

  // FinalizeReviewDialog.tsx:124-141
  @discardableResult
  func answer(_ item: FinalizeReviewScreen.Item, _ answer: Answer) async -> Bool {
    guard !deciding else { return false }
    deciding = true
    defer { deciding = false }
    let (decision, edit, reason): (FinalizeDecision, [String: JSONValue]?, String?) =
      switch answer {
      case .keep: (.kept, nil, nil)
      case .edit(let patch): (.edited, patch, nil)
      case .skip(let reason): (.skipped, nil, reason)
      }
    do throws(FinalizeAnswerError) {
      try await store.decideFinalizeItem(novel: novel, chapter: chapter, item: item.key, decision: decision, edit: edit, reason: reason)
      setMode(nil, for: item.key)
      return true
    } catch {
      problems[item.key] = FinalizeErrors.presented(error)
      return false
    }
  }

  // FinalizeReviewDialog.tsx:143-154
  @discardableResult
  func keepRoutine() async -> PresentedError? {
    guard !deciding else { return nil }
    deciding = true
    defer { deciding = false }
    do throws(FinalizeAnswerError) {
      try await store.keepRoutineFinalizeItems(novel: novel, chapter: chapter)
      return nil
    } catch {
      return FinalizeErrors.presented(error)
    }
  }

  // FinalizeReviewDialog.tsx:156-162
  @discardableResult
  func setAutoKeep(_ category: FinalizeCategory, on: Bool, current: [FinalizeCategory]) async -> PresentedError? {
    do throws(DomainError) {
      try await store.setFinalizeAutoKeep(novel: novel, categories: FinalizeReviewDisplay.toggled(current, category, on: on))
      return nil
    } catch {
      return FinalizeErrors.presented(error)
    }
  }

  // FinalizeReviewDialog.tsx:169-182: the dialog stays open on the applied state instead of closing.
  @discardableResult
  func finalize() async -> Bool {
    guard !finalizing else { return false }
    finalizing = true
    defer { finalizing = false }
    refusal = nil
    do throws(DomainError) {
      try await store.finalizeChapter(novel: novel, chapter: chapter)
      finalized = true
      return true
    } catch {
      refusal = FinalizeErrors.presented(error)
      return false
    }
  }

  func problem(for item: String) -> PresentedError? { problems[item] }

  func closeForms() {
    modes = [:]
    problems = [:]
  }
}
