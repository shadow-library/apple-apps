import ShadowCore
import ShadowStore

public enum MetricsError: ShadowError {
  case store(StoreError)
  case record(MemoirRecordError)
  case issue(CommandIssueError)
  case calendar(CalendarError)
  case refused(CommandRefusal)
  case metricAbsent(MetricReference)
  case builtinFixed(BuiltinMetric)
  case notReader(HealthReaderDesignation?)

  public var referenceCode: String? {
    switch self {
    case .metricAbsent: "MET_002"
    case .builtinFixed: "MET_003"
    case .refused(let refusal): refusal.referenceCode
    case .store, .record, .issue, .calendar, .notReader: nil
    }
  }

  public var code: String {
    switch self {
    case .store(let error): error.code
    case .record(let error): error.code
    case .issue(let error): error.code
    case .calendar(let error): error.code
    case .refused(let refusal): refusal.code
    case .metricAbsent: "memoir_metrics.metric_absent"
    case .builtinFixed: "memoir_metrics.builtin_fixed"
    case .notReader: "memoir_metrics.not_reader"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .store(let error): error.errorDescription
    case .record(let error): error.errorDescription
    case .issue(let error): error.errorDescription
    case .calendar(let error): error.errorDescription
    case .refused(let refusal): refusal.errorDescription
    case .metricAbsent(let metric): "Metric \(metric.id.lowercasedString) is not in the \(metric.metricClass.rawValue) store."
    case .builtinFixed(let metric): "The built-in metric \(metric.rawValue) keeps its definition and class."
    case .notReader(let designation?): "\(designation.name) reads Apple Health for this vault; this device does not."
    case .notReader(nil): "No device has been chosen to read Apple Health for this vault."
    }
  }

  /// A store write's body throws its own error, which the store wraps as `aborted`.
  init(_ error: StoreError) {
    switch error {
    case .aborted(let inner as MetricsError): self = inner
    case .aborted(let inner as MemoirRecordError): self = .record(inner)
    case .aborted(let inner as CalendarError): self = .calendar(inner)
    case .aborted(let inner as CommandIssueError): self = .issue(inner)
    default: self = .store(error)
    }
  }
}

@discardableResult
func metricsCall<T>(_ body: () async throws(StoreError) -> T) async throws(MetricsError) -> T {
  do {
    return try await body()
  } catch {
    throw MetricsError(error)
  }
}
