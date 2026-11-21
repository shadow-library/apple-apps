import Foundation
import NovelForgeCore
import Observation
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore

/// One novel's Waiting on you, read once for the compact badge and the home it opens, or for the chat's tray: both count the rows the home lists.
@MainActor
@Observable
final class PendingModel {
  private let observer = ReadObserver<PendingSnapshot>()
  private(set) var generation = 0

  var state: Loadable<PendingSnapshot> { observer.state }

  var changesAt: Date? { observer.state.value?.changesAt }

  func list(replica: ReplicaID, standing: JobsStanding) -> PendingList {
    observer.state.value.map { PendingItems.list($0, replica: replica, standing: standing) } ?? .empty
  }

  func observe(_ context: NovelContext, now: LeaseInstant) async {
    let (store, query) = (context.store, PendingQuery(novel: context.novel, replica: context.store.replica, now: now))
    await observer.run { store.observeReads { transaction in try PendingSnapshot.load(query, in: transaction) } }
  }

  func retry() {
    generation += 1
  }
}

/// Where a row takes the author.
nonisolated enum PendingDestination: Equatable, Sendable {
  /// The chat holding the card, scrolled to it.
  case chat(UUID, ChatFocusTarget)
  /// Plan cards staged with no chat, shown with Plan next chapter.
  case plans
  case chapter(Int)
  /// The approved chapter's read of its Story Bible updates, presented in place.
  case finalize(Int)

  /// A card in a chat this device does not list (deleted, or not received yet) has nowhere to be shown.
  @MainActor static func of(_ item: PendingItem, listed: (UUID) -> Bool) -> PendingDestination? {
    switch item.kind {
    case .chat(let chat):
      if chat.isPlan { return .plans }
      return ChatTrayText.chat(of: chat, listed: listed).map { .chat($0, chat.target) }
    case .review(let chapter, _): return .chapter(chapter)
    case .finalize(let chapter, _): return .finalize(chapter)
    case .job(let job): return .chapter(job.chapter)
    }
  }
}

/// What a row does when tapped or when one of its buttons is: navigation goes through the novel's navigator, a job's action runs on this device's runtime
/// and stays on screen, and the finalize dialog, the consent sheet, a refusal and the stop confirmation are presented by the screen holding the rows.
@MainActor
@Observable
final class PendingActions {
  var finalizing: Int?
  var failure: PresentedError?
  var consent: AIConsentRequest?
  var stopping: PendingJob?

  func open(_ destination: PendingDestination, navigator: NovelNavigator, chats: ChatNovelModel?) {
    switch destination {
    case .chat(let session, let target):
      navigator.show(.chat)
      chats?.reveal(target, in: session)
    case .plans:
      navigator.show(.chat)
      chats?.waiting.revealPlans()
    case .chapter(let chapter): navigator.openAbove(.reader, ReaderRoute.chapter(chapter))
    case .finalize(let chapter): finalizing = chapter
    }
  }

  /// Cancel asks first, as the chapter's strip does; Review Permission opens the consent sheet the runtime waits for.
  func perform(_ action: ChapterJobLine.Action, on job: PendingJob, novel: UUID, runtime: JobRuntime?) async {
    guard let runtime else {
      failure = JobsErrors.notRunningHere
      return
    }
    switch action {
    case .runHere: failure = await runtime.runHere(job.line.job)
    case .resume: failure = await runtime.resume(job.line.job)
    case .tryAgain: failure = await runtime.tryAgain(job.line.job)
    case .retryRead: failure = await runtime.retryRead(novel: novel, chapter: job.chapter, shown: job.line.job)
    case .allow: consent = runtime.consentNeeded
    case .cancel: stopping = job
    }
  }

  func stop(_ job: PendingJob, runtime: JobRuntime?) async {
    stopping = nil
    guard let runtime else {
      failure = JobsErrors.notRunningHere
      return
    }
    failure = await runtime.cancel(job.line.job)
  }
}
