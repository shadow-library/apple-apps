import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

enum ReviewSaveStatus: Equatable {
  case idle
  case saving
  case saved
}

/// `features/review/index.tsx`: last week in the steps of the modules that are on (reflection and the close always). The answers and the week's
/// completion stay on this device (`WeeklyReviewAnswers`), and a review already finished opens on its last step.
@MainActor
@Observable
final class WeeklyReviewModel {
  private let context: MemoirScreenContext
  let bodyClasses: Set<SyncClass>
  let day: ReflectDayFollower
  let review = ReadObserver<WeeklyReview>()
  let lookups = ReadObserver<ReflectLookups>()
  private(set) var modules = ModuleSelection.all
  private(set) var step = ReviewStep.kept
  private(set) var furthest = ReviewStep.kept
  var drafts = [ReviewPrompt: String]()
  private(set) var status = [ReviewPrompt: ReviewSaveStatus]()
  private(set) var isFinishing = false
  var failure: PresentedError?
  /// The week the drafts and the step belong to; a new week starts the review over.
  private(set) var week: LocalDate?
  private var stored = [ReviewPrompt: String]()

  init(context: MemoirScreenContext, bodyClasses: Set<SyncClass> = ReflectBody.onThisDevice) {
    self.context = context
    self.bodyClasses = bodyClasses
    day = ReflectDayFollower(context: context)
  }

  var isComplete: Bool { review.state.value?.answers.isComplete ?? false }

  var steps: [ReviewStep] { modules.reviewSteps }

  func apply(_ selection: ModuleSelection) {
    guard selection != modules else { return }
    modules = selection
    step = valid(step)
    furthest = valid(furthest)
  }

  private func valid(_ step: ReviewStep) -> ReviewStep {
    let steps = steps
    guard !steps.contains(step) else { return step }
    return steps.first { $0.position > step.position } ?? .done
  }

  func followToday() async {
    await day.follow()
  }

  func observe() async {
    guard let today = day.day?.today else { return }
    let stores = context.stores
    let bodyClasses = modules.readableBodyClasses(bodyClasses)
    await review.run {
      ReflectReads.observeReview(in: stores, bodyClasses: bodyClasses, today: today)
    } onValue: { [weak self] review in
      self?.received(review)
    }
  }

  func observeLookups() async {
    let main = context.stores.main
    await lookups.run { main.observe(ReflectLookups.self, ReflectLookupsQuery(streaks: false)) }
  }

  func show(_ step: ReviewStep) async {
    guard steps.contains(step) else { return }
    await saveAll()
    reach(step)
  }

  func back() async {
    let steps = steps
    guard let index = steps.firstIndex(of: step), index > 0 else { return }
    await saveAll()
    step = steps[index - 1]
  }

  /// Continue; on the reflection step of an unfinished review this finishes it (`advance`, `features/review/index.tsx:76-82`).
  func advance() async {
    if step == .reflect, !isComplete {
      await finish()
      return
    }
    let steps = steps
    guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
    await saveAll()
    reach(steps[index + 1])
  }

  /// Saves what is typed, then closes the week on this device.
  func finish() async {
    guard !isFinishing, let week else { return }
    isFinishing = true
    defer { isFinishing = false }
    guard await saveAll() else { return }
    failure = nil
    do {
      try await WeeklyReviewAnswers.complete(week: week, atMillis: MemoirClock.millis(context.clock.now()), in: context.stores)
      reach(.done)
    } catch {
      failure = WritingErrors.presented(error) ?? PresentedError(error)
    }
  }

  /// Saves one answer if it changed; an empty answer removes it. A draft left from a week that has since ended is never written, since a write for one
  /// week clears every other week's answers.
  @discardableResult
  func save(_ prompt: ReviewPrompt) async -> Bool {
    guard let week, isCurrent(week) else { return false }
    let answer = drafts[prompt] ?? ""
    guard answer != (stored[prompt] ?? "") else { return true }
    status[prompt] = .saving
    failure = nil
    do {
      try await WeeklyReviewAnswers.save(answer, for: prompt, week: week, in: context.stores)
      guard self.week == week else { return false }
      stored[prompt] = answer.isEmpty ? nil : answer
      status[prompt] = .saved
      return true
    } catch {
      status[prompt] = .idle
      failure = WritingErrors.presented(error) ?? PresentedError(error)
      return false
    }
  }

  @discardableResult
  func saveAll() async -> Bool {
    var saved = true
    for prompt in ReviewPrompt.allCases {
      if await !save(prompt) { saved = false }
    }
    return saved
  }

  /// Whether `week` is still the one under review on the followed day: the review on screen can lag a day turn until its read restarts.
  private func isCurrent(_ week: LocalDate) -> Bool {
    guard let today = day.day?.today else { return false }
    return WeeklyReview.weekUnderReview(today: today)?.start == week
  }

  /// Marks a prompt as being edited again, so "Saved" no longer shows under it.
  func edited(_ prompt: ReviewPrompt) {
    if status[prompt] == .saved { status[prompt] = .idle }
  }

  private func reach(_ step: ReviewStep) {
    self.step = step
    if step.position > furthest.position { furthest = step }
  }

  /// A new week (the first read, or a day turn into the next week) starts on its first step, or on the last when it is already closed; within a week,
  /// answers saved elsewhere replace only the drafts that hold no unsaved change.
  private func received(_ review: WeeklyReview) {
    let answers = review.answers.answers
    guard week == review.week.start else {
      week = review.week.start
      drafts = answers
      stored = answers
      status = [:]
      step = review.answers.isComplete ? .done : steps[0]
      furthest = step
      return
    }
    for prompt in ReviewPrompt.allCases where (drafts[prompt] ?? "") == (stored[prompt] ?? "") {
      drafts[prompt] = answers[prompt]
    }
    stored = answers
  }
}
