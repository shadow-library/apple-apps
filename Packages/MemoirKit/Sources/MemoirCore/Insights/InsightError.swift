import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore

/// Every description is free of the owner's data: an attempt's error is stored in its synced job record.
public enum InsightError: ShadowError {
  case questionLength(Int)
  case scheduleMinuteOutOfRange(Int)
  /// The reference's `AI_009`: the reply had no usable answer (prompt-contract.ts:33-37).
  case unusableAnswer
  /// The reference's `AI_013`: the model or the provider declined the request; it is not retried.
  case refused
  case truncated
  case model(code: String)
  case routing(TaskRouterError)
  case guardrailBlocked([GuardrailViolation])
  case contextTooLarge(units: Int, budget: Int)
  /// Consent changed while the context was assembled, every time it was assembled again.
  case consentUnsettled
  case replayUnavailable(String)
  case notAnInsightJob(EntityRef)
  case store(StoreError)
  case record(MemoirRecordError)
  case job(JobRecordError)
  case run(JobRunError)
  case key(JobKeyError)

  public var code: String {
    switch self {
    case .questionLength: "insight.question_length"
    case .scheduleMinuteOutOfRange: "insight.schedule_minute_out_of_range"
    case .unusableAnswer: "insight.unusable_answer"
    case .refused: "insight.refused"
    case .truncated: "insight.truncated"
    case .model(let code): code
    case .routing(let error): error.code
    case .guardrailBlocked: "insight.guardrail_blocked"
    case .contextTooLarge: "insight.context_too_large"
    case .consentUnsettled: "insight.consent_unsettled"
    case .replayUnavailable: "insight.replay_unavailable"
    case .notAnInsightJob: "insight.not_an_insight_job"
    case .store(let error): error.code
    case .record(let error): error.code
    case .job(let error): error.code
    case .run(let error): error.code
    case .key(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .questionLength(let length): "A question has 1 to \(InsightQuestion.maximumLength) characters, not \(length)."
    case .scheduleMinuteOutOfRange(let minute): "\(minute) is not a minute of the day."
    case .unusableAnswer: "The AI service did not return a usable answer."
    case .refused: "The AI service refused this request."
    case .truncated: "The answer was cut off at its output limit."
    case .model(let code): "The AI service failed (\(code))."
    case .routing(let error): error.errorDescription
    case .guardrailBlocked(let violations): "The answer was withheld by the output guardrails: \(violations.map(\.rawValue).joined(separator: ","))."
    case .contextTooLarge(let units, let budget): "Even the last week of data (\(units) units) does not fit the prompt budget of \(budget)."
    case .consentUnsettled: "Consent kept changing while the data was gathered, so nothing was sent."
    case .replayUnavailable(let code): "The derived hero state could not be read (\(code))."
    case .notAnInsightJob(let ref): "\(ref.kind)/\(ref.key) is not an insight job."
    case .store(let error): error.errorDescription
    case .record(let error): error.errorDescription
    case .job(let error): error.errorDescription
    case .run(let error): error.errorDescription
    case .key(let error): error.errorDescription
    }
  }

  /// A write's own error, unwrapped from the store's `aborted`.
  static func converting(_ error: StoreError) -> InsightError {
    guard case .aborted(let inner) = error else { return .store(error) }
    switch inner {
    case let inner as InsightError: return inner
    case let inner as MemoirRecordError: return .record(inner)
    case let inner as JobRecordError: return .job(inner)
    case let inner as StoreError: return converting(inner)
    default: return .store(error)
    }
  }

  private static let retryableCodes: Set<String> = [
    "insight.unusable_answer", "insight.truncated", "insight.replay_unavailable", "jobs.step_failed", "model.rate_limited", "model.overloaded", "model.server",
    "model.transport", "model.mid_stream", "model.malformed_response", "model.not_recorded",
  ]

  private static let holdCodes: Set<String> = [
    "routing.consent_required", "routing.daily_spend_limit", "routing.monthly_spend_limit", "routing.spend_unavailable", "insight.consent_unsettled",
  ]

  /// The reference retries an unusable answer and an unreachable model up to its attempt limit and never a refusal or a guardrail block
  /// (ai-executor.service.ts:139-150).
  public static func isRetryable(code: String) -> Bool {
    retryableCodes.contains(code) || isHold(code: code) || code.hasPrefix("store.")
  }

  /// A call that could not be sent then: a consent withdrawn or a spend cap reached after the attempt began. Such a failure is retried without counting
  /// towards the attempt limit, as the reference holds and requeues the task (ai-executor.service.ts:120-124, 201-215).
  public static func isHold(code: String) -> Bool {
    holdCodes.contains(code)
  }
}
