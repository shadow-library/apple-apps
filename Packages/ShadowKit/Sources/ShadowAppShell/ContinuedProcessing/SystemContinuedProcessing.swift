import Foundation
import OSLog
import ShadowCore

#if os(iOS)
  import BackgroundTasks
#endif

#if os(iOS)
  /// One per process: the system kills an app that registers the same identifier twice, so each wildcard reaches `BGTaskScheduler` once and a later
  /// registration only replaces the handler.
  public final class SystemContinuedProcessingScheduler: ContinuedProcessingScheduler {
    public static let shared = SystemContinuedProcessingScheduler()

    nonisolated private static let logger = Logger(category: "jobs")

    private var launches: [String: @MainActor (any ContinuedProcessingTask) -> Void] = [:]

    private init() {}

    public func register(_ wildcard: String, launch: @escaping @MainActor (any ContinuedProcessingTask) -> Void) {
      let first = launches.updateValue(launch, forKey: wildcard) == nil
      guard first else { return }
      let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: wildcard, using: .main) { task in
        MainActor.assumeIsolated { SystemContinuedProcessingScheduler.shared.launched(task, under: wildcard) }
      }
      if !registered { Self.logger.error("The continued-processing identifier is not in the Info.plist wildcard=\(wildcard, privacy: .public)") }
    }

    public func submit(_ request: ContinuedProcessingRequest) async throws(ContinuedProcessingRefusal) {
      try await Self.send(request)
    }

    private func launched(_ task: BGTask, under wildcard: String) {
      guard let task = task as? BGContinuedProcessingTask, let launch = launches[wildcard] else { return task.setTaskCompleted(success: false) }
      launch(SystemContinuedProcessingTask(task))
    }

    /// `BGTaskScheduler` asks that submissions stay off the main thread.
    @concurrent
    nonisolated private static func send(_ request: ContinuedProcessingRequest) async throws(ContinuedProcessingRefusal) {
      let task = BGContinuedProcessingTaskRequest(identifier: request.identifier, title: request.title, subtitle: request.subtitle)
      task.strategy = .fail
      do {
        if #available(iOS 27, *) {
          try await BGTaskScheduler.shared.submitTaskRequest(task)
        } else {
          try BGTaskScheduler.shared.submit(task)
        }
      } catch let error as BGTaskScheduler.Error {
        throw ContinuedProcessingRefusal(error.code)
      } catch {
        throw .unknown(code: (error as NSError).code)
      }
    }
  }

  public final class SystemContinuedProcessingTask: ContinuedProcessingTask {
    private let task: BGContinuedProcessingTask

    public init(_ task: BGContinuedProcessingTask) {
      self.task = task
    }

    public var identifier: String { task.identifier }

    /// The system calls the handler on a queue of its own.
    public func onExpiration(_ handler: @escaping @MainActor () -> Void) {
      task.expirationHandler = { @Sendable in Task { @MainActor in handler() } }
    }

    public func report(_ units: ContinuedProcessingUnits) {
      task.progress.totalUnitCount = units.total
      task.progress.completedUnitCount = units.completed
    }

    public func update(title: String, subtitle: String) {
      task.updateTitle(title, subtitle: subtitle)
    }

    public func complete(success: Bool) {
      task.setTaskCompleted(success: success)
    }
  }

  extension ContinuedProcessingRefusal {
    public nonisolated init(_ code: BGTaskScheduler.Error.Code) {
      self =
        switch code {
        case .immediateRunIneligible: .ineligible
        case .unavailable: .unavailable
        case .notPermitted: .notPermitted
        case .tooManyPendingTaskRequests: .tooManyPending
        @unknown default: .unknown(code: code.rawValue)
        }
    }
  }
#endif
