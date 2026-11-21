import Foundation

#if canImport(UIKit)
  import UIKit
#endif

enum SyncBackgroundWork {
  typealias Runner = @MainActor (_ name: String, _ work: @escaping @MainActor () async -> Void) async -> Void

  /// On iOS the work runs inside a background task, ended once when the work returns or the system says time is up, whichever comes first; the work
  /// itself is not stopped, so changes it did not send stay queued for the next run.
  static func system(_ name: String, _ work: @escaping @MainActor () async -> Void) async {
    #if canImport(UIKit)
      let assertion = BackgroundAssertion(name: name)
      await work()
      assertion.end()
    #else
      await work()
    #endif
  }

  /// True when `work` finished within `timeout`; past it the caller goes on while the work keeps running.
  static func bounded(_ timeout: Duration, _ work: @escaping @MainActor () async -> Void) async -> Bool {
    await withCheckedContinuation { continuation in
      var resumed = false
      let finish: @MainActor (Bool) -> Void = { finished in
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: finished)
      }
      Task { @MainActor in
        await work()
        finish(true)
      }
      Task { @MainActor in
        try? await Task.sleep(for: timeout)
        finish(false)
      }
    }
  }
}

#if canImport(UIKit)
  private final class BackgroundAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
      identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
      guard identifier != .invalid else { return }
      UIApplication.shared.endBackgroundTask(identifier)
      identifier = .invalid
    }
  }
#endif
