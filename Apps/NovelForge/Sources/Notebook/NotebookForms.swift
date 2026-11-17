import Foundation
import NovelForgeCore
import Observation

enum NotebookFormMode: Equatable {
  case add(LedgerEntryKind)
  case rewrite(NotebookEntry)
}

enum NotebookLimits {
  static let statement = 4000
  static let why = 4000
  static let writerLine = 1000
  static let reason = 4000
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
  fileprivate var length: Int { utf16.count }
}

@MainActor
@Observable
final class NotebookEntryForm {
  static let addKinds: [LedgerEntryKind] = [.direction, .rejected, .backlog]

  let mode: NotebookFormMode
  var kind: LedgerEntryKind
  var topic = ""
  var statement: String
  var why: String
  var writerLine: String
  private(set) var issues = NotebookFormIssues.none
  private(set) var isSubmitting = false
  private let original: Original

  private struct Original {
    let kind: LedgerEntryKind
    let statement: String
    let why: String
    let writerLine: String
  }

  init(mode: NotebookFormMode) {
    self.mode = mode
    switch mode {
    case .add(let kind):
      original = Original(kind: kind, statement: "", why: "", writerLine: "")
    case .rewrite(let entry):
      let known = entry.record.entryKind.known ?? .decision
      original = Original(kind: known == .system ? .decision : known, statement: entry.record.statement, why: entry.record.why ?? "", writerLine: entry.record.writerLine ?? "")
    }
    kind = original.kind
    statement = original.statement
    why = original.why
    writerLine = original.writerLine
  }

  var isRewrite: Bool {
    if case .rewrite = mode { return true }
    return false
  }

  var kinds: [LedgerEntryKind] {
    guard isRewrite else { return Self.addKinds }
    return original.kind == .decision ? [.decision] + Self.addKinds : Self.addKinds
  }
  var showsWriterLine: Bool { isRewrite && kind == .decision }
  var normalizedTopic: String { topic.trimmed.lowercased().replacingOccurrences(of: " ", with: "-") }

  var topicIssue: String? {
    guard !isRewrite, !normalizedTopic.isEmpty else { return issues.topic }
    if NotebookTopics.isReserved(normalizedTopic) { return NotebookErrors.headline(for: .reservedTopic(normalizedTopic)) }
    guard NotebookTopics.isKey(normalizedTopic) else { return NotebookErrors.headline(for: .malformedTopic(normalizedTopic)) }
    return issues.topic
  }

  var statementIssue: String? {
    guard statement.length <= NotebookLimits.statement else { return NotebookErrors.headline(for: .tooLong(field: "statement", limit: NotebookLimits.statement)) }
    return issues.statement
  }

  var whyIssue: String? {
    guard why.length > NotebookLimits.why else { return nil }
    return NotebookErrors.headline(for: .tooLong(field: "why", limit: NotebookLimits.why))
  }

  var writerLineIssue: String? {
    guard showsWriterLine, writerLine.length > NotebookLimits.writerLine else { return nil }
    return NotebookErrors.headline(for: .tooLong(field: "writerLine", limit: NotebookLimits.writerLine))
  }

  var hasChanges: Bool {
    switch mode {
    case .add: !statement.trimmed.isEmpty || !why.trimmed.isEmpty || !topic.trimmed.isEmpty
    case .rewrite: kind != original.kind || statement.trimmed != original.statement.trimmed || why.trimmed != original.why.trimmed || writerChanged
    }
  }

  var canSubmit: Bool {
    guard !isSubmitting, !statement.trimmed.isEmpty, hasChanges else { return false }
    guard statement.length <= NotebookLimits.statement, whyIssue == nil, writerLineIssue == nil else { return false }
    return isRewrite || (!normalizedTopic.isEmpty && topicIssue == nil)
  }

  func edited() {
    issues = .none
  }

  func submit(using model: NotebookModel) async -> UUID? {
    guard canSubmit else { return nil }
    isSubmitting = true
    issues = .none
    defer { isSubmitting = false }
    do {
      switch mode {
      case .add:
        return try await model.add(AuthorNotebookEntry(kind: kind, topic: normalizedTopic, statement: statement.trimmed, why: why.trimmed.isEmpty ? nil : why.trimmed))
      case .rewrite(let entry):
        let rewrite = NotebookRewrite(
          kind: kind == original.kind ? nil : kind, statement: statement.trimmed, why: why.trimmed, writerLine: showsWriterLine ? writerLine.trimmed : nil)
        return try await model.rewrite(entry.id, as: rewrite)
      }
    } catch {
      issues = NotebookFormIssues(error)
      return nil
    }
  }

  private var writerChanged: Bool {
    showsWriterLine && writerLine.trimmed != original.writerLine.trimmed
  }
}

@MainActor
@Observable
final class NotebookWithdrawForm {
  let entry: NotebookEntry
  var reason = ""
  private(set) var issues = NotebookFormIssues.none
  private(set) var isSubmitting = false

  init(entry: NotebookEntry) {
    self.entry = entry
  }

  var hasChanges: Bool { !reason.trimmed.isEmpty }

  var reasonIssue: String? {
    guard reason.length <= NotebookLimits.reason else { return NotebookErrors.headline(for: .tooLong(field: "reason", limit: NotebookLimits.reason)) }
    return issues.reason
  }

  var canSubmit: Bool {
    !isSubmitting && !reason.trimmed.isEmpty && reason.length <= NotebookLimits.reason
  }

  func edited() {
    issues = .none
  }

  func submit(using model: NotebookModel) async -> Bool {
    guard canSubmit else { return false }
    isSubmitting = true
    issues = .none
    defer { isSubmitting = false }
    do {
      try await model.withdraw(entry.id, reason: reason.trimmed)
      return true
    } catch {
      issues = NotebookFormIssues(error)
      return false
    }
  }
}
