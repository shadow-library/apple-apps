import Foundation
import Observation

#if canImport(UIKit)
  import UIKit
#endif

@MainActor
@Observable
final class UnsavedWork {
  typealias Flush = @MainActor () async -> Void

  static let shared = UnsavedWork()

  private var flushes: [UUID: Flush] = [:]

  var hasWork: Bool { !flushes.isEmpty }

  func register(_ flush: @escaping Flush) -> UUID {
    let token = UUID()
    flushes[token] = flush
    return token
  }

  func unregister(_ token: UUID) {
    flushes[token] = nil
  }

  func flushAll() async {
    for flush in Array(flushes.values) { await flush() }
  }

  func flushAll(within timeout: Duration) async {
    await withCheckedContinuation { continuation in
      var finished = false
      let finish: @MainActor () -> Void = {
        guard !finished else { return }
        finished = true
        continuation.resume()
      }
      Task { @MainActor in
        await self.flushAll()
        finish()
      }
      Task { @MainActor in
        try? await Task.sleep(for: timeout)
        finish()
      }
    }
  }

  func flushBeforeSuspending() async {
    #if canImport(UIKit) && !os(watchOS)
      let application = UIApplication.shared
      var identifier = UIBackgroundTaskIdentifier.invalid
      identifier = application.beginBackgroundTask(withName: "flush-unsaved-work") { application.endBackgroundTask(identifier) }
      await flushAll(within: .seconds(20))
      if identifier != .invalid { application.endBackgroundTask(identifier) }
    #else
      await flushAll(within: .seconds(5))
    #endif
  }
}
