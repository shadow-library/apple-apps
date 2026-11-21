import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore

/// `ai_task_kind` (schemas/ai.ts:38).
public enum InsightJobKind: String, CaseIterable, Sendable {
  case adhoc = "insight_adhoc"
  case scheduled = "insight_scheduled"
}

/// The owner's question: 1 to 2,000 characters, as the reference's DTO counts them (ai.dto.ts:28-29, code points).
public enum InsightQuestion {
  public static let maximumLength = 2000

  public static func validated(_ question: String) throws(InsightError) -> String {
    let length = question.unicodeScalars.count
    guard (1...maximumLength).contains(length) else { throw .questionLength(length) }
    return question
  }
}

/// An insight job's key. The vault is one owner's, so every insight shares one scope; a scheduled job targets its local date, so every device that finds
/// the same night due asks for the same job, as the reference derives the night's task id from account and date (scheduled-query.repository.ts:25-31);
/// an ad-hoc job targets the question's own id. The fingerprint is the prompt version.
public enum InsightJobAddress {
  public static let scope = "memoir.insights"
  private static let datePrefix = "date:"
  private static let questionPrefix = "question:"

  public static func key(_ kind: InsightJobKind, target: InsightJobTarget, run: Int = 1) throws(InsightError) -> JobKey {
    do {
      return try JobKey(scope: scope, kind: kind.rawValue, target: target.text, fingerprint: InsightPrompt.version, run: run)
    } catch {
      throw .key(error)
    }
  }

  public static func kind(of key: JobKey) -> InsightJobKind? {
    guard key.scope == scope else { return nil }
    return InsightJobKind(rawValue: key.kind)
  }

  public static func target(of key: JobKey) -> InsightJobTarget? {
    if key.target.hasPrefix(datePrefix), let date = LocalDate(isoString: String(key.target.dropFirst(datePrefix.count))) {
      let target = InsightJobTarget.night(date)
      return target.text == key.target ? target : nil
    }
    guard key.target.hasPrefix(questionPrefix), let question = UUID(uuidString: String(key.target.dropFirst(questionPrefix.count))) else { return nil }
    let target = InsightJobTarget.question(question)
    return target.text == key.target ? target : nil
  }

  static func text(of target: InsightJobTarget) -> String {
    switch target {
    case .night(let date): datePrefix + date.isoString
    case .question(let id): questionPrefix + id.lowercasedString
    }
  }
}

public enum InsightJobTarget: Sendable, Hashable {
  case night(LocalDate)
  case question(UUID)

  var text: String { InsightJobAddress.text(of: self) }
}

public enum InsightJobOriginMember: String, CaseIterable, Sendable {
  case source
  case date
  case question
}

/// Where an insight job came from: the standing question on a night, or a question the owner asked.
public enum InsightJobOrigin {
  public static func json(_ target: InsightJobTarget) -> JSONValue {
    switch target {
    case .night(let date): [InsightJobOriginMember.source.rawValue: "scheduled", InsightJobOriginMember.date.rawValue: .string(date.isoString)]
    case .question(let id): [InsightJobOriginMember.source.rawValue: "adhoc", InsightJobOriginMember.question.rawValue: .string(id.lowercasedString)]
    }
  }
}

public enum InsightJobPayloadMember: String, CaseIterable, Sendable {
  case question
}

/// An insight job as its request recorded it.
struct InsightJob: Sendable {
  let kind: InsightJobKind
  let target: InsightJobTarget
  let question: String
  let ref: EntityRef

  init(_ job: JobRecord) throws(InsightError) {
    let key = job.request.key
    guard
      let kind = InsightJobAddress.kind(of: key), let target = InsightJobAddress.target(of: key),
      let question = job.request.payload.objectValue?[InsightJobPayloadMember.question.rawValue]?.stringValue
    else { throw .notAnInsightJob(job.ref) }
    switch (kind, target) {
    case (.scheduled, .night), (.adhoc, .question): break
    case (.scheduled, .question), (.adhoc, .night): throw .notAnInsightJob(job.ref)
    }
    self.kind = kind
    self.target = target
    self.question = try InsightQuestion.validated(question)
    ref = job.ref
  }

  static func request(_ kind: InsightJobKind, target: InsightJobTarget, question: String, replica: ReplicaID, run: Int = 1) throws(InsightError) -> JobRequest {
    JobRequest(
      key: try InsightJobAddress.key(kind, target: target, run: run), payload: [InsightJobPayloadMember.question.rawValue: .string(try InsightQuestion.validated(question))],
      origin: InsightJobOrigin.json(target), replica: replica)
  }
}
