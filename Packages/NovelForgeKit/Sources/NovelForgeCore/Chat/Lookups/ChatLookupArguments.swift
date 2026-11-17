enum UsagePeriod: String, CaseIterable, Sendable {
  case today
  case week
  case month
  case all
}

struct ChatLookupIssue: Equatable, Sendable {
  let path: String
  let message: String

  var text: String { "\(path): \(message)" }
}

struct ChatLookupArgumentError: Error, Equatable, Sendable {
  let issues: [ChatLookupIssue]

  // chat-lookup.service.ts:83
  var text: String { "error: \(issues.map(\.text).joined(separator: "; "))" }
}

enum ChatLookupRequest: Equatable, Sendable {
  case bibleDocument(section: BiblePageSection, slug: String)
  case brief(chapter: Double)
  case draft(chapter: Double)
  case entity(key: String)
  case canonFacts(keys: [String])
  case chapterSummaries(from: Double, to: Double)
  case plotThreads(status: ThreadStatus?)
  case volume(key: String)
  case notes(from: Double?, part: Double?, query: String?)
  case usage(chapter: Double?, period: UsagePeriod?, lastRun: Bool?)

  // planner-only-guard.ts:13 reads the parsed arguments
  var plannerGuardArguments: OrderedJSON? {
    guard case .bibleDocument(let section, let slug) = self else { return nil }
    return .object(OrderedJSONObject([(key: "section", value: .string(section.rawValue)), (key: "slug", value: .string(slug))]))
  }
}

extension ChatLookupName {
  // the zod schemas in apps/novel-forge-server/src/modules/ai/tools/tools/*.tool.ts: unknown keys are stripped, every issue is collected, then the refinement runs
  func parse(_ arguments: OrderedJSONObject) throws(ChatLookupArgumentError) -> ChatLookupRequest {
    var reader = ArgumentReader(fields: arguments)
    let request: ChatLookupRequest?
    switch self {
    case .getBibleDocument:
      let section = reader.choice("section", among: BiblePageSection.allCases.map(\.rawValue))
      let slug = reader.string("slug")
      request = section.flatMap { BiblePageSection(rawValue: $0) }.flatMap { section in slug.map { .bibleDocument(section: section, slug: $0) } }
    case .getBrief: request = reader.integer("chapter", minimum: 1).map { .brief(chapter: $0) }
    case .getDraft: request = reader.integer("chapter", minimum: 1).map { .draft(chapter: $0) }
    case .getEntity: request = reader.string("entityKey").map { .entity(key: $0) }
    case .getVolume: request = reader.string("volumeKey").map { .volume(key: $0) }
    case .getCanonFacts: request = reader.strings("keys", minimumCount: 1, maximumCount: 20).map { .canonFacts(keys: $0) }
    case .getChapterSummaries:
      let from = reader.integer("from", minimum: 1)
      let to = reader.integer("to", minimum: 1)
      request = from.flatMap { from in to.map { .chapterSummaries(from: from, to: $0) } }
      if case .chapterSummaries(let from, let to)? = request, to - from > 20 { reader.refine("Chapter range must not exceed 20") }
    case .getPlotThreads:
      let status = reader.choice("status", among: ["closed", "open", "dropped"], required: false)
      request = reader.issues.isEmpty ? .plotThreads(status: status.flatMap { ThreadStatus(rawValue: $0) }) : nil
    case .getNotes:
      let from = reader.integer("from", minimum: 1, required: false)
      let part = reader.integer("part", minimum: 1, required: false)
      let query = reader.string("query", trimmed: true, minimumLength: 1, required: false)
      request = reader.issues.isEmpty ? .notes(from: from, part: part, query: query) : nil
    case .getUsage:
      let chapter = reader.integer("chapter", minimum: 1, required: false)
      let period = reader.choice("period", among: UsagePeriod.allCases.map(\.rawValue), required: false)
      let lastRun = reader.boolean("last_run", required: false)
      request = reader.issues.isEmpty ? .usage(chapter: chapter, period: period.flatMap { UsagePeriod(rawValue: $0) }, lastRun: lastRun) : nil
    }
    guard reader.issues.isEmpty, let request else { throw ChatLookupArgumentError(issues: reader.issues) }
    return request
  }
}

private struct ArgumentReader {
  let fields: OrderedJSONObject
  private(set) var issues: [ChatLookupIssue] = []

  init(fields: OrderedJSONObject) {
    self.fields = fields
  }

  mutating func refine(_ message: String) {
    issues.append(ChatLookupIssue(path: "", message: message))
  }

  mutating func string(_ key: String, trimmed: Bool = false, minimumLength: Int = 0, required: Bool = true) -> String? {
    guard let value = present(key, required: required) else { return nil }
    guard case .string(let raw) = value else { return fail(key, "Expected string, received \(typeName(of: value))") }
    let text = trimmed ? raw.jsTrim() : raw
    guard text.jsLength >= minimumLength else { return fail(key, "String must contain at least \(minimumLength) character(s)") }
    return text
  }

  /// A number that fails a check is still a number, so the refinement of the whole object still reads it.
  mutating func integer(_ key: String, minimum: Double, required: Bool = true) -> Double? {
    guard let value = present(key, required: required) else { return nil }
    guard let number = value.numberValue else { return fail(key, "Expected number, received \(typeName(of: value))") }
    if !number.jsIsInteger { issues.append(ChatLookupIssue(path: key, message: "Expected integer, received float")) }
    if number < minimum { issues.append(ChatLookupIssue(path: key, message: "Number must be greater than or equal to \(minimum.jsString)")) }
    return number
  }

  mutating func boolean(_ key: String, required: Bool = true) -> Bool? {
    guard let value = present(key, required: required) else { return nil }
    guard case .bool(let flag) = value else { return fail(key, "Expected boolean, received \(typeName(of: value))") }
    return flag
  }

  mutating func choice(_ key: String, among values: [String], required: Bool = true) -> String? {
    guard let value = present(key, required: required) else { return nil }
    let listed = values.map { "'\($0)'" }.joined(separator: " | ")
    guard case .string(let raw) = value else { return fail(key, "Expected \(listed), received \(typeName(of: value))") }
    guard values.contains(where: { $0.jsEquals(raw) }) else { return fail(key, "Invalid enum value. Expected \(listed), received '\(raw)'") }
    return raw
  }

  mutating func strings(_ key: String, minimumCount: Int, maximumCount: Int) -> [String]? {
    guard let value = present(key, required: true) else { return nil }
    guard case .array(let items) = value else { return fail(key, "Expected array, received \(typeName(of: value))") }
    let before = issues.count
    if items.count < minimumCount { issues.append(ChatLookupIssue(path: key, message: "Array must contain at least \(minimumCount) element(s)")) }
    if items.count > maximumCount { issues.append(ChatLookupIssue(path: key, message: "Array must contain at most \(maximumCount) element(s)")) }
    var texts: [String] = []
    for (index, item) in items.enumerated() {
      let path = "\(key).\(index)"
      guard case .string(let text) = item else {
        issues.append(ChatLookupIssue(path: path, message: "Expected string, received \(typeName(of: item))"))
        continue
      }
      if text.isEmpty { issues.append(ChatLookupIssue(path: path, message: "String must contain at least 1 character(s)")) }
      texts.append(text)
    }
    return issues.count == before ? texts : nil
  }

  private mutating func present(_ key: String, required: Bool) -> OrderedJSON? {
    if let value = fields[key] { return value }
    if required { issues.append(ChatLookupIssue(path: key, message: "Required")) }
    return nil
  }

  private mutating func fail<Value>(_ key: String, _ message: String) -> Value? {
    issues.append(ChatLookupIssue(path: key, message: message))
    return nil
  }

  private func typeName(of value: OrderedJSON) -> String {
    switch value {
    case .null: "null"
    case .bool: "boolean"
    case .int, .double: "number"
    case .string: "string"
    case .array: "array"
    case .object: "object"
    }
  }
}
