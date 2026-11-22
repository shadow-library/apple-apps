import Foundation
import Observation

#if canImport(UIKit)
  import UIKit
#endif

@MainActor
@Observable
public final class UnsavedWork {
  public typealias Flush = @MainActor () async -> Void

  public static let shared = UnsavedWork()

  private var flushes: [UUID: Flush] = [:]

  public init() {}

  public var hasWork: Bool { !flushes.isEmpty }

  public func register(_ flush: @escaping Flush) -> UUID {
    let token = UUID()
    flushes[token] = flush
    return token
  }

  public func unregister(_ token: UUID) {
    flushes[token] = nil
  }

  public func flushAll() async {
    for flush in Array(flushes.values) { await flush() }
  }

  public func flushAll(within timeout: Duration) async {
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

  public func flushBeforeSuspending() async {
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
