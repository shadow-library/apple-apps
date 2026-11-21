#if os(macOS)
  import Foundation
  import NovelForgeCore
  import ShadowJobs
  import SwiftUI

  /// The oldest run going here, with its kind once read and its progress from `observeRun`.
  struct WorkerRun: Equatable {
    let run: JobRunHere
    var kind: NovelJobKind?
    var progress: JobRunProgress?
  }

  /// What the menu-bar item says the worker is doing.
  enum WorkerMenuStatus: Equatable {
    enum Wait: Equatable {
      case libraryClosed
      case starting
      case anotherCopy
      case unavailable
      case consent
      case workerUnreadable
    }

    case idle
    /// `others` is how many more runs go here beside the one shown.
    case running(kind: NovelJobKind?, step: AttemptStep?, others: Int)
    case waiting(Wait)

    /// A run going here is shown even while the queue waits for consent; nothing runs while the library is closed or another copy holds its jobs.
    init(mode: JobRuntime.Mode?, consentNeeded: Bool, runs: Int, run: WorkerRun?, worker: VaultWorker?) {
      switch mode {
      case nil: self = .waiting(.libraryClosed)
      case .starting: self = .waiting(.starting)
      case .elsewhere: self = .waiting(.anotherCopy)
      case .unavailable: self = .waiting(.unavailable)
      case .running:
        if runs > 0 {
          self = .running(kind: run?.kind, step: run?.progress?.step, others: runs - 1)
        } else if consentNeeded {
          self = .waiting(.consent)
        } else if case .unreadable = worker {
          self = .waiting(.workerUnreadable)
        } else {
          self = .idle
        }
      }
    }

    var isRunning: Bool {
      guard case .running = self else { return false }
      return true
    }

    var title: Text {
      switch self {
      case .idle: Text("No jobs to run", tableName: "Worker")
      case .running(let kind?, _, _): JobDisplay.title(kind)
      case .running(nil, _, _): Text("Running a job", tableName: "Worker")
      case .waiting(.libraryClosed): Text("Waiting for the library to open", tableName: "Worker")
      case .waiting(.starting): Text("Getting ready to run jobs", tableName: "Worker")
      case .waiting(.anotherCopy): Text("Another copy of Novel Forge runs this library's jobs", tableName: "Worker")
      case .waiting(.unavailable): Text("Jobs can't run on this Mac right now", tableName: "Worker")
      case .waiting(.consent): Text("Waiting for your permission to send the novel's text", tableName: "Worker")
      case .waiting(.workerUnreadable): Text("This Mac can't read which Mac runs jobs", tableName: "Worker")
      }
    }

    var detail: Text? {
      guard case .running(let kind, let step, let others) = self else { return nil }
      let progress = kind.flatMap { kind in step.map { JobDisplay.progress(kind, $0) } }
      let more = others > 0 ? String(localized: "and \(others) more", table: "Worker") : nil
      let parts = [progress, more].compactMap { $0 }
      return parts.isEmpty ? nil : Text(verbatim: parts.joined(separator: " · "))
    }
  }
#endif
