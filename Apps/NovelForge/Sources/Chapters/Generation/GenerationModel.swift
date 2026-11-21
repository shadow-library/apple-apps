import Foundation
import NovelForgeCore
import Observation
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
  case waitingForConsent
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

  init(novel: UUID, chapter: Int) {
    self.novel = novel
    self.chapter = chapter
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
    case .runningElsewhere, .waitingForConsent: notice = outcome
    }
    return outcome
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
        runtime.follow(handle)
        return .started
      case .elsewhere: return .runningElsewhere
      }
    } catch .engine(.consentRequired) {
      return .waitingForConsent
    } catch {
      return .refused(GenerationErrors.presented(error))
    }
  }
}
