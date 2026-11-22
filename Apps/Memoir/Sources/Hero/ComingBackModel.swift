import Foundation
import MemoirCore
import Observation
import ShadowAppShell

struct IntensityFailure: Equatable {
  let mode: IntensityMode
  let error: PresentedError
}

/// The Coming back screen's read and its one write, the intensity, which replay stages for the next day the walk opens.
@MainActor
@Observable
final class ComingBackModel {
  let comingBack = ReadObserver<ComingBack>()
  private(set) var pendingIntensity: IntensityMode?
  private(set) var dismissedOn: LocalDate?
  var failure: IntensityFailure?

  private let context: MemoirScreenContext
  private let dismissal: ComingBackDismissal

  init(context: MemoirScreenContext, dismissal: ComingBackDismissal = ComingBackDismissal()) {
    self.context = context
    self.dismissal = dismissal
  }

  func run() async {
    let main = context.stores.main
    await comingBack.run {
      main.observe(ComingBack.self, ComingBackQuery())
    } onValue: { [dismissal] value in
      dismissedOn = value.openDay.flatMap { dismissal.isDismissed(on: $0) ? $0 : nil }
    }
  }

  /// The staged mode, unless it is the one already in force (`pendingValue` in `synced-account-provider.ts`).
  var stagedIntensity: IntensityMode? {
    guard let value = comingBack.state.value, let pending = value.pendingIntensityMode, pending != value.intensityMode else { return nil }
    return pending
  }

  var effectiveIntensity: IntensityMode? {
    guard let value = comingBack.state.value else { return nil }
    return stagedIntensity ?? value.intensityMode
  }

  var isDismissed: Bool {
    guard let day = comingBack.state.value?.openDay else { return false }
    return dismissedOn == day
  }

  func setIntensity(_ mode: IntensityMode) async {
    guard pendingIntensity == nil, let effective = effectiveIntensity, mode != effective else { return }
    pendingIntensity = mode
    defer { pendingIntensity = nil }
    do {
      try await context.writer.issue(.accountSetIntensityMode(IntensityModeChange(mode: mode)))
    } catch {
      failure = WritingErrors.presented(error).map { IntensityFailure(mode: mode, error: $0) }
    }
  }

  func dismiss() {
    guard let day = comingBack.state.value?.openDay else { return }
    dismissal.dismiss(on: day)
    dismissedOn = day
  }
}
