import ShadowCore

public enum ProgressOverrideKind: String, CaseIterable, Sendable {
  case undecided
  case dismissed
}

public enum ProgressStatus: String, CaseIterable, Sendable {
  case open
  case answered
  case undecided
  case dismissed
}

public enum ProgressItemKey: String, CaseIterable, Sendable {
  case premise
  case protagonist
  case opposition
  case theme
  case readerPromise = "reader_promise"
  case ending
  case firstVolumeGoal = "first_volume_goal"
  case nextChapterPlanned = "next_chapter_planned"
}

struct ProgressOverride<ID: Hashable & Sendable>: Equatable, Sendable {
  var status: ProgressOverrideKind
  var entryId: ID
}

struct ProgressOverrideEntry<ID: Hashable & Sendable>: Equatable, Sendable {
  var id: ID
  var kind: String
  var topic: String
  var payload: JSONValue?
}

struct ProgressFields: Equatable, Sendable {
  var premise: String?
  var protagonistKey: String?
  var opposition: String?
  var theme: String?
  var readerPromise: String?
  var endingQuestion: String?
  var ending: String?
  var firstVolumeGoal: String?
  var nextChapterPlanned: Bool
  var chapterOneWritten: Bool
}

struct ProgressItem<ID: Hashable & Sendable>: Equatable, Sendable {
  var key: ProgressItemKey
  var label: String
  var why: String
  var status: ProgressStatus
  var overrideEntryId: ID?
}

struct ProgressProjectFields: Equatable, Sendable {
  var premise: String?
  var protagonistKey: String?
  var opposition: String?
  var theme: String?
  var readerPromise: String?
  var endingQuestion: String?
  var ending: String?
}

struct ProgressNextChapter: Equatable, Sendable {
  struct Brief: Equatable, Sendable {
    var staleReason: String?
  }

  var chapter: Int
  var brief: Brief?
}

// apps/novel-forge-server/src/common/progress.ts:1
let progressTopicPrefix = "progress."

// apps/novel-forge-server/src/common/progress.ts:3
func progressKeyFromTopic(_ topic: String) -> String? {
  topic.jsStartsWith(progressTopicPrefix) ? topic.jsSlice(progressTopicPrefix.jsLength) : nil
}

private func overrideKind(_ payload: JSONValue?) -> ProgressOverrideKind? {
  guard case .object(let fields) = payload, case .string(let status) = fields["status"] else { return nil }
  return ProgressOverrideKind.allCases.first { $0.rawValue.jsEquals(status) }
}

// apps/novel-forge-server/src/common/progress.ts:30
func progressOverridesFrom<ID>(_ entries: [ProgressOverrideEntry<ID>]) -> [JSString: ProgressOverride<ID>] {
  var overrides: [JSString: ProgressOverride<ID>] = [:]
  for entry in entries {
    guard entry.kind.jsEquals("system"), let key = progressKeyFromTopic(entry.topic), !key.isEmpty, let status = overrideKind(entry.payload) else { continue }
    overrides[JSString(key)] = ProgressOverride(status: status, entryId: entry.id)
  }
  return overrides
}

private func filled(_ value: String?) -> Bool {
  guard let value else { return false }
  return !value.jsTrim().isEmpty
}

private struct ProgressCheck {
  let key: ProgressItemKey
  let label: String
  let why: String
  let hasAnswer: @Sendable (ProgressFields) -> Bool
  let appliesWhile: @Sendable (ProgressFields) -> Bool

  init(
    _ key: ProgressItemKey,
    _ label: String,
    _ why: String,
    appliesWhile: @escaping @Sendable (ProgressFields) -> Bool = { _ in true },
    hasAnswer: @escaping @Sendable (ProgressFields) -> Bool
  ) {
    self.key = key
    self.label = label
    self.why = why
    self.hasAnswer = hasAnswer
    self.appliesWhile = appliesWhile
  }
}

// apps/novel-forge-server/src/common/progress.ts:73
private let progressChecks: [ProgressCheck] = [
  ProgressCheck(.premise, "Premise", "The one- or two-line idea the chat and every later decision build on.") { filled($0.premise) },
  ProgressCheck(.protagonist, "Protagonist", "Who the reader follows; scenes and knowledge are written from their point of view.") { filled($0.protagonistKey) },
  ProgressCheck(.opposition, "Opposition", "What or who pushes back, so chapters have something to write against.") { filled($0.opposition) },
  ProgressCheck(.theme, "Theme", "What the book is about underneath the plot.") { filled($0.theme) },
  ProgressCheck(.readerPromise, "Reader promise", "What the reader is waiting for and expects to be paid off.") { filled($0.readerPromise) },
  ProgressCheck(.ending, "Ending", "How the book ends. Planner-only — never shown to the reader early — and fine to leave undecided for now.") {
    filled($0.endingQuestion) || filled($0.ending)
  },
  ProgressCheck(.firstVolumeGoal, "First volume goal", "What changes by the end of volume one.") { filled($0.firstVolumeGoal) },
  ProgressCheck(
    .nextChapterPlanned,
    "Next chapter planned",
    "A short plan for the next chapter, agreed with the chat before it is written.",
    appliesWhile: { !$0.chapterOneWritten },
    hasAnswer: { $0.nextChapterPlanned }
  ),
]

// apps/novel-forge-server/src/common/progress.ts:95
let progressItemKeys: [ProgressItemKey] = progressChecks.map(\.key)

// apps/novel-forge-server/src/common/progress.ts:101
func computeProgress<ID>(_ fields: ProgressFields, overrides: [JSString: ProgressOverride<ID>]) -> [ProgressItem<ID>] {
  progressChecks.filter { $0.appliesWhile(fields) }.map { check in
    if let override = overrides[JSString(check.key.rawValue)] {
      return ProgressItem(key: check.key, label: check.label, why: check.why, status: override.status.progressStatus, overrideEntryId: override.entryId)
    }
    return ProgressItem(key: check.key, label: check.label, why: check.why, status: check.hasAnswer(fields) ? .answered : .open, overrideEntryId: nil)
  }
}

extension ProgressOverrideKind {
  var progressStatus: ProgressStatus {
    switch self {
    case .undecided: .undecided
    case .dismissed: .dismissed
    }
  }
}

// apps/novel-forge-server/src/common/progress.ts:125
func progressFieldsFrom(_ project: ProgressProjectFields, volumeObjectives: [String?], next: ProgressNextChapter) -> ProgressFields {
  ProgressFields(
    premise: project.premise,
    protagonistKey: project.protagonistKey,
    opposition: project.opposition,
    theme: project.theme,
    readerPromise: project.readerPromise,
    endingQuestion: project.endingQuestion,
    ending: project.ending,
    firstVolumeGoal: volumeObjectives.first ?? nil,
    nextChapterPlanned: next.brief.map { $0.staleReason?.isEmpty ?? true } ?? false,
    chapterOneWritten: next.chapter > 1
  )
}
