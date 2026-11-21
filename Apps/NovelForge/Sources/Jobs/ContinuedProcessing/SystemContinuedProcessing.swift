import Foundation
import OSLog

#if os(iOS)
  import BackgroundTasks
#endif

enum JobRunHosts {
  /// Continued processing on iPhone and iPad; on the Mac a run goes on while the app runs, so the foreground host is enough.
  static func system() -> any JobRunHost {
    #if os(iOS)
      ContinuedProcessingHost(scheduler: SystemContinuedProcessingScheduler.shared)
    #else
      ForegroundRunHost()
    #endif
  }
}

#if os(iOS)
  /// One per process: the system kills an app that registers the same identifier twice, so each wildcard reaches `BGTaskScheduler` once and a later
  /// registration only replaces the handler.
  final class SystemContinuedProcessingScheduler: ContinuedProcessingScheduler {
    static let shared = SystemContinuedProcessingScheduler()

    nonisolated private static let logger = Logger(subsystem: "com.shadow.apps.novelforge", category: "jobs")

    private var launches: [String: @MainActor (any ContinuedProcessingTask) -> Void] = [:]

    private init() {}

    func register(_ wildcard: String, launch: @escaping @MainActor (any ContinuedProcessingTask) -> Void) {
      let first = launches.updateValue(launch, forKey: wildcard) == nil
      guard first else { return }
      let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: wildcard, using: .main) { task in
        MainActor.assumeIsolated { SystemContinuedProcessingScheduler.shared.launched(task, under: wildcard) }
      }
      if !registered { Self.logger.error("The continued-processing identifier is not in the Info.plist wildcard=\(wildcard, privacy: .public)") }
    }

    func submit(_ request: ContinuedProcessingRequest) async throws(ContinuedProcessingRefusal) {
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

  final class SystemContinuedProcessingTask: ContinuedProcessingTask {
    private let task: BGContinuedProcessingTask

    init(_ task: BGContinuedProcessingTask) {
      self.task = task
    }

    var identifier: String { task.identifier }

    /// The system calls the handler on a queue of its own.
    func onExpiration(_ handler: @escaping @MainActor () -> Void) {
      task.expirationHandler = { @Sendable in Task { @MainActor in handler() } }
    }

    func report(_ units: ContinuedProcessingUnits) {
      task.progress.totalUnitCount = units.total
      task.progress.completedUnitCount = units.completed
    }

    func update(title: String, subtitle: String) {
      task.updateTitle(title, subtitle: subtitle)
    }

    func complete(success: Bool) {
      task.setTaskCompleted(success: success)
    }
  }

  extension ContinuedProcessingRefusal {
    nonisolated init(_ code: BGTaskScheduler.Error.Code) {
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
