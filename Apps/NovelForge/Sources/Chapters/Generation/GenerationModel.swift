import Foundation
import NovelForgeCore
import Observation
import ShadowAI
import ShadowAppShell
import ShadowJobs
import ShadowStore

nonisolated enum GenerationKind: Sendable, Equatable {
  case generate
  case regenerate
}

enum GenerationOutcome: Equatable {
  case started
  /// Requested for the device that runs it; its line offers Run here.
  case queued
  case runningElsewhere
  case waitingForConsent(AIConsentRequest)
  case refused(PresentedError)
}

@MainActor
@Observable
final class GenerationModel {
  let novel: UUID
  let chapter: Int
  private(set) var isStarting = false
  private(set) var notice: GenerationOutcome?
  var failure: PresentedError?
  var consent: AIConsentRequest?
  var needsProvider = false
  private var awaitingProvider: GenerationKind?

  init(novel: UUID, chapter: Int) {
    self.novel = novel
    self.chapter = chapter
  }

  func ask(_ kind: GenerationKind, providerReady: Bool) -> GenerationKind? {
    guard !providerReady else { return kind }
    awaitingProvider = kind
    needsProvider = true
    return nil
  }

  func providerConnected() -> GenerationKind? {
    defer { awaitingProvider = nil }
    return awaitingProvider
  }

  @discardableResult
  func start(_ kind: GenerationKind, options: GenerationOptions, runtime: JobRuntime?) async -> GenerationOutcome {
    guard !isStarting else { return .started }
    isStarting = true
    defer { isStarting = false }
    let outcome = await request(kind, options: options, runtime: runtime)
    notice = nil
    switch outcome {
    case .refused(let error): failure = error
    case .started, .queued: break
    case .runningElsewhere: notice = outcome
    case .waitingForConsent(let request):
      notice = outcome
      consent = request
    }
    return outcome
  }

  func consentAllowed(on runtime: JobRuntime?) {
    notice = nil
    runtime?.consentAllowed()
  }

  /// ChapterList.tsx:147: only a run that is queued, waiting or running blocks asking again; a failed one does not.
  static func isBusy(_ line: ChapterJobLine) -> Bool {
    if case .failed = line.state { return false }
    return true
  }

  private func request(_ kind: GenerationKind, options: GenerationOptions, runtime: JobRuntime?) async -> GenerationOutcome {
    guard let runtime, let engine = runtime.engine else { return .refused(JobsErrors.notRunningHere) }
    do throws(GenerationRequestError) {
      guard runtime.startsWhenAsked(.generate) else {
        _ = try await engine.requestGeneration(novel: novel, chapter: chapter, options: options, regenerating: kind == .regenerate)
        return .queued
      }
      let started =
        switch kind {
        case .generate: try await engine.generateChapter(novel: novel, chapter: chapter, options: options)
        case .regenerate: try await engine.regenerateChapter(novel: novel, chapter: chapter, options: options)
        }
      switch started {
      case .running(let handle):
        runtime.follow(handle, origin: .person)
        return .started
      case .elsewhere: return .runningElsewhere
      }
    } catch .engine(.consentRequired(let request)) {
      return .waitingForConsent(request)
    } catch {
      return .refused(GenerationErrors.presented(error))
    }
  }
}
