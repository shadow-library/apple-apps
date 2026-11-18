import ShadowCore
import ShadowJobs
import ShadowStore

public enum JobEngineError: ShadowError {
  /// This vault already has a running engine: two would each run attempts the other cannot see in its running set.
  case engineExists
  case chapterOutOfRange(Int)
  case key(JobKeyError)
  case jobNotFound(EntityRef)
  /// The job's scope, kind or target is not one a novel's job has, so no pipeline of this app runs it.
  case notANovelJob(EntityRef)
  case pipelineNotYetAvailable(NovelJobKind)
  /// Another device's attempt holds a live lease, so "Run here" is not offered (plan, Jobs and devices).
  case runningElsewhere(AttemptID, ReplicaID)
  /// The attempt was started by another version of its pipeline, whose checkpoint this one cannot read.
  case pipelineChanged(running: Int, pinned: Int?)
  case pins(DomainError)
  case writerPack(code: String, description: String?)
  case run(JobRunError)
  case record(JobRecordError)
  case store(StoreError)

  public var code: String {
    switch self {
    case .engineExists: "job_engine.engine_exists"
    case .chapterOutOfRange: "job_engine.chapter_out_of_range"
    case .key(let error): error.code
    case .jobNotFound: "job_engine.job_not_found"
    case .notANovelJob: "job_engine.not_a_novel_job"
    case .pipelineNotYetAvailable: "job_engine.pipeline_not_yet_available"
    case .runningElsewhere: "job_engine.running_elsewhere"
    case .pipelineChanged: "job_engine.pipeline_changed"
    case .pins(let error): error.code
    case .writerPack(let code, _): code
    case .run(let error): error.code
    case .record(let error): error.code
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .engineExists: "This vault already has a job engine running."
    case .chapterOutOfRange(let chapter): "\(chapter) is not a chapter number; chapters start at 1."
    case .key(let error): error.errorDescription
    case .jobNotFound(let ref): "Job \(ref.key) has not arrived or cannot be read."
    case .notANovelJob(let ref): "Job \(ref.key) is not a job of a novel."
    case .pipelineNotYetAvailable(let kind): "Jobs of kind \(kind.rawValue) cannot run in this version yet."
    case .runningElsewhere(let attempt, let replica): "Device \(replica) is running the job as attempt \(attempt.uuid.lowercasedString)."
    case .pipelineChanged(let running, let pinned): "The attempt was started by pipeline version \(pinned.map(String.init) ?? "unknown"), not \(running)."
    case .pins(let error): error.errorDescription
    case .writerPack(_, let description): description
    case .run(let error): error.errorDescription
    case .record(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }
}

extension JobEngineError {
  init(_ error: WriterPackError) {
    self = .writerPack(code: error.code, description: error.errorDescription)
  }
}
