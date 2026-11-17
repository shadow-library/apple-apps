import Foundation
import NovelForgeCore

struct StreamedLookup: Equatable, Identifiable {
  let id: String
  let tool: String
  let label: String
  var status: TurnLookupStatus
}

/// What a running turn has shown so far, folded from its events: a reset voids the reply and the changes, never the lookups
/// (apps/novel-forge-web/src/lib/chat-turn-timeline.ts:130-135).
struct StreamedTurn: Equatable {
  enum Write: Equatable {
    case reply
    case change
  }

  let turn: UUID
  let startedAt: Date
  private(set) var text = ""
  private(set) var lookups: [StreamedLookup] = []
  private(set) var changes: [TurnChangeEvent] = []
  private(set) var lastWrite: Write?
  private(set) var reply: UUID?
  private(set) var failure: TurnFailure?
  private(set) var isFinished = false

  init(turn: UUID, startedAt: Date) {
    self.turn = turn
    self.startedAt = startedAt
  }

  var hasShownAnything: Bool { !text.isEmpty || !lookups.isEmpty || !changes.isEmpty }

  mutating func apply(_ event: TurnStreamEvent) {
    switch event {
    case .user:
      return
    case .lookup(let lookup):
      let id = "\(lookup.tool)\u{0}\(lookup.argumentsJSON)"
      if let index = lookups.firstIndex(where: { $0.id == id }) {
        lookups[index].status = lookup.status
      } else {
        lookups.append(StreamedLookup(id: id, tool: lookup.tool, label: ChatLookupLabel.label(tool: lookup.tool, argumentsJSON: lookup.argumentsJSON), status: lookup.status))
      }
    case .delta(let delta):
      text += delta
      lastWrite = .reply
    case .change(let change):
      if let index = changes.firstIndex(where: { $0.index == change.index }) {
        changes[index] = change
      } else {
        changes.append(change)
      }
      lastWrite = .change
    case .reset:
      text = ""
      changes = []
      lastWrite = nil
    case .done(let reply):
      self.reply = reply
    case .error(let failure):
      self.failure = failure
    }
  }

  mutating func finish() {
    isFinished = true
  }

  var runningLookup: StreamedLookup? { lookups.last { $0.status == .running } }

  /// chat-turn-timeline.ts:124-128: while the turn runs, a source still being read belongs to the tail.
  func settledLookups(live: Bool) -> [StreamedLookup] {
    live ? lookups.filter { $0.status != .running } : lookups
  }
}

/// The lines a turn draws, as apps/novel-forge-web/src/lib/chat-turn-timeline.ts words them.
enum ChatTurnTimeline {
  /// chat-turn-timeline.ts:64-67
  static let slowAfter: TimeInterval = 45

  static var slowNote: String { String(localized: "This one's taking longer than usual. The model is still answering.", table: "Chat") }

  /// chat-turn-timeline.ts:137-143 over chat-turn-phase.ts:18-28.
  static func tail(_ turn: StreamedTurn, mode: ChatSessionMode) -> String {
    if let lookup = turn.runningLookup { return ChatLookupLabel.reading(lookup) }
    switch turn.lastWrite {
    case .reply: return String(localized: "Writing", table: "Chat")
    case .change: return saving(turn.changes.count, mode: mode)
    case nil: return String(localized: "Thinking", table: "Chat")
    }
  }

  /// chat-turn-timeline.ts:80-82
  static func saving(_ count: Int, mode: ChatSessionMode) -> String {
    switch mode {
    case .auto: String(localized: "Saving \(count) changes to your Story Bible", table: "Chat")
    case .manual: String(localized: "Preparing \(count) suggestions", table: "Chat")
    }
  }

  /// chat-turn-timeline.ts:108-121, without the per-kind nouns: the count of sources read and of those that failed.
  static func readSummary(_ lookups: [StreamedLookup]) -> String {
    let failed = lookups.count { $0.status == .error }
    let read = lookups.count - failed
    guard read > 0 else { return String(localized: "Couldn't read \(failed) sources", table: "Chat") }
    let summary = String(localized: "Read \(read) sources", table: "Chat")
    guard failed > 0 else { return summary }
    return summary + " · " + String(localized: "\(failed) couldn't be read", table: "Chat")
  }

  /// chat-turn-timeline.ts:145-149
  static func worked(_ seconds: TimeInterval, stopped: Bool, sources: Int) -> String {
    let elapsed = elapsed(seconds)
    let lead = stopped ? String(localized: "Stopped after \(elapsed)", table: "Chat") : String(localized: "Worked \(elapsed)", table: "Chat")
    guard sources > 0 else { return lead }
    return lead + " · " + String(localized: "read \(sources) sources", table: "Chat")
  }

  /// apps/novel-forge-web/src/lib/format.ts:170-174
  static func elapsed(_ seconds: TimeInterval) -> String {
    let whole = max(0, Int(seconds))
    guard whole >= 60 else { return "\(whole)s" }
    return "\(whole / 60)m \(String(format: "%02d", whole % 60))s"
  }
}

/// apps/novel-forge-web/src/lib/chat-lookup-label.ts: a lookup named by what it read, from the arguments the model sent.
enum ChatLookupLabel {
  private static let queryLimit = 40

  static var generic: String { String(localized: "Looked something up", table: "Chat") }

  static func label(tool: String, argumentsJSON: String) -> String {
    let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
    return label(tool: tool, arguments: arguments)
  }

  /// chat-turn-timeline.ts:101-106
  static func reading(_ lookup: StreamedLookup) -> String {
    guard lookup.label != generic else { return String(localized: "Looking something up", table: "Chat") }
    let subject = lookup.tool == "get_bible_document" ? lookup.label : lowerFirst(lookup.label)
    return String(localized: "Reading \(subject)", table: "Chat")
  }

  // chat-lookup-label.ts:78-100
  private static func label(tool: String, arguments: [String: Any]) -> String {
    switch tool {
    case "get_bible_document": bible(arguments)
    case "get_brief": chapter(arguments["chapter"]).map { String(localized: "Chapter \($0) plan", table: "Chat") } ?? String(localized: "A chapter plan", table: "Chat")
    case "get_draft": chapter(arguments["chapter"]).map { String(localized: "Chapter \($0) draft", table: "Chat") } ?? String(localized: "A chapter draft", table: "Chat")
    case "get_canon_facts": String(localized: "Canon facts", table: "Chat")
    case "get_chapter_summaries": summaries(arguments)
    case "get_entity":
      text(arguments["entityKey"]).map { String(localized: "Profile of \(capitalise(humanise($0)))", table: "Chat") } ?? String(localized: "A profile", table: "Chat")
    case "get_notes": notes(arguments)
    case "get_plot_threads":
      text(arguments["status"]).map { String(localized: "\(capitalise($0)) plot threads", table: "Chat") } ?? String(localized: "Plot threads", table: "Chat")
    case "get_usage": String(localized: "Usage figures", table: "Chat")
    case "get_volume":
      text(arguments["volumeKey"]).map { String(localized: "Volume plan: \(capitalise(humanise($0)))", table: "Chat") } ?? String(localized: "A volume plan", table: "Chat")
    default: generic
    }
  }

  // chat-lookup-label.ts:27-32
  private static func bible(_ arguments: [String: Any]) -> String {
    if let slug = text(arguments["slug"]) { return capitalise(humanise(slug)) }
    if let section = text(arguments["section"]) { return String(localized: "\(capitalise(humanise(section))) page", table: "Chat") }
    return String(localized: "Story Bible page", table: "Chat")
  }

  // chat-lookup-label.ts:43-48
  private static func summaries(_ arguments: [String: Any]) -> String {
    guard let from = chapter(arguments["from"]), let to = chapter(arguments["to"]) else { return String(localized: "Chapter summaries", table: "Chat") }
    return from == to ? String(localized: "Summary of chapter \(from)", table: "Chat") : String(localized: "Summaries of chapters \(from)–\(to)", table: "Chat")
  }

  // chat-lookup-label.ts:34-41
  private static func notes(_ arguments: [String: Any]) -> String {
    if let from = chapter(arguments["from"]) { return String(localized: "Notes from ¶\(from)", table: "Chat") }
    if let part = chapter(arguments["part"]) { return String(localized: "Notes, part \(part)", table: "Chat") }
    guard let query = text(arguments["query"]) else { return String(localized: "Your notes", table: "Chat") }
    return String(localized: "Notes mentioning \(quoted(query))", table: "Chat")
  }

  private static func text(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// A whole number only: the reference prints any finite number, and the lookups take whole chapters and paragraphs.
  private static func chapter(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return Int(exactly: number.doubleValue)
  }

  // chat-lookup-label.ts:13-16
  private static func humanise(_ key: String) -> String {
    let name = key.split(whereSeparator: { $0 == ":" || $0 == "/" }).last.map(String.init) ?? key
    return name.split(whereSeparator: { $0 == "-" || $0 == "_" }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
  }

  private static func capitalise(_ value: String) -> String {
    value.prefix(1).uppercased() + value.dropFirst()
  }

  private static func lowerFirst(_ value: String) -> String {
    value.prefix(1).lowercased() + value.dropFirst()
  }

  // chat-lookup-label.ts:18-20
  private static func quoted(_ query: String) -> String {
    guard query.count > queryLimit else { return "“\(query)”" }
    var cut = query.prefix(queryLimit)
    while cut.last?.isWhitespace == true { cut.removeLast() }
    return "“\(cut)…”"
  }
}
