import ShadowAI
import ShadowText

/// One element of the reply's top-level `changeSet`, numbered from 0 among those shown since the last reset.
struct StreamedChange: Equatable, Sendable {
  let index: Int
  let element: ChangeSetElement
}

/// What the relay shows of a reply being written; provisional, since only the settled turn says what the reply held.
enum ReplyStreamEvent: Equatable, Sendable {
  /// Never empty.
  case delta(String)
  case change(StreamedChange)
  /// Everything shown since the last reset is void.
  case reset
}

// apps/novel-forge-server/src/modules/ai/model-router.service.ts:236
private let sentenceEnd = builtInPattern(#"[.!?\n]["'”’)\]]*"#, flags: "g")

/// Port of the reference's `ReplyStreamRelay` (apps/novel-forge-server/src/modules/ai/model-router.service.ts:245-330) over the events of a streamed structured call.
/// `refuses` makes it release the reply a whole sentence at a time, each screened first, so refused text is never shown; a refused change is never shown either.
struct ReplyStreamRelay: Sendable {
  private let refuses: (@Sendable (String) -> Bool)?
  private var scanner = ReplyScanner()
  private var streamed = ""
  private var changes: [String] = []
  private var held = ""
  private var withheld = false

  init(refuses: (@Sendable (String) -> Bool)? = nil) {
    self.refuses = refuses
  }

  /// An unrestricted reply is screened against the hard line at the role's output scope (model-router.service.ts:477).
  init(contentMode: ContentMode, role: String = "chat") {
    guard contentMode == .unrestricted else {
      self.init()
      return
    }
    let scope = outputScope(role: role)
    self.init(refuses: { findHardLine([$0], scope: scope) != nil })
  }

  /// False while no top-level `reply` string has begun; such a reply streams no text at all (model-router.service.ts:516).
  var replyFound: Bool { scanner.state != .awaitingReply }

  /// A new attempt and a reset both start over, as the reference's `streamOnce` and a Synapse reset do (model-router.service.ts:822-825). Completion settles
  /// nothing: the caller screens the output first, then calls `settle(_:)`, or `restart()` when the screen refuses it (model-router.service.ts:761-781).
  mutating func receive(_ event: StructuredStreamEvent) -> [ReplyStreamEvent] {
    switch event {
    case .attemptStarted, .reset: restart()
    case .textDelta(let chunk): push(chunk)
    case .completed: []
    }
  }

  // model-router.service.ts:269
  mutating func push(_ chunk: String) -> [ReplyStreamEvent] {
    var text = ""
    var elements: [ChangeSetElement] = []
    for event in scanner.consume(chunk) {
      switch event {
      case .reply(let decoded): text += decoded
      case .element(let element): elements.append(element)
      }
    }
    var events: [ReplyStreamEvent] = []
    if !text.isEmpty {
      streamed += text
      events += forward(text, final: false)
    }
    for element in visible(elements) {
      events.append(.change(StreamedChange(index: changes.count, element: element)))
      changes.append(Self.canonical(element))
    }
    return events
  }

  // model-router.service.ts:281
  mutating func restart() -> [ReplyStreamEvent] {
    scanner = ReplyScanner()
    held = ""
    withheld = false
    guard !streamed.isEmpty || !changes.isEmpty else { return [] }
    streamed = ""
    changes = []
    return [.reset]
  }

  /// Settles against the accepted JSON: a reset is not a full settle, since an answer taken from a later value of the shown attempt emits none.
  mutating func settle(_ result: StructuredResult) -> [ReplyStreamEvent] {
    settle(raw: String(decoding: result.json, as: UTF8.self))
  }

  // model-router.service.ts:290
  mutating func settle(raw: String) -> [ReplyStreamEvent] {
    let flushed = forward("", final: true)
    guard !streamed.isEmpty || !changes.isEmpty else { return flushed }
    var final = ReplyScanner()
    var reply = ""
    var elements: [ChangeSetElement] = []
    for event in final.consume(raw) {
      switch event {
      case .reply(let decoded): reply += decoded
      case .element(let element): elements.append(element)
      }
    }
    let settled = visible(elements).map(Self.canonical)
    let same = streamed.jsEquals(reply) && settled.count == changes.count && zip(settled, changes).allSatisfy { $0.jsEquals($1) }
    return same ? flushed : flushed + [.reset]
  }

  // model-router.service.ts:300; an element too deeply nested to read cannot be screened, so an unrestricted reply never shows it.
  private func visible(_ elements: [ChangeSetElement]) -> [ChangeSetElement] {
    guard let refuses else { return elements }
    return elements.filter { element in
      guard let value = try? OrderedJSON(parsing: element.source) else { return false }
      return !refuses(Self.stringLeaves(value).joined(separator: "\n"))
    }
  }

  // model-router.service.ts:307. `held` never holds a sentence end before the new text is added, so the last sentence end is found in the new text alone.
  private mutating func forward(_ text: String, final: Bool) -> [ReplyStreamEvent] {
    guard let refuses else { return text.isEmpty ? [] : [.delta(text)] }
    guard !withheld else { return [] }
    let previous = held.jsLength
    held += text
    let cut = final ? held.jsLength : text.jsMatchAll(sentenceEnd).last.map { previous + $0.endIndex } ?? 0
    guard cut > 0 else { return [] }
    let ready = held.jsSlice(0, cut)
    held = held.jsSlice(cut)
    guard !refuses(ready) else {
      withheld = true
      held = ""
      return []
    }
    return [.delta(ready)]
  }

  /// What the reference compares, `JSON.stringify` of the parsed element (model-router.service.ts:276).
  private static func canonical(_ element: ChangeSetElement) -> String {
    (try? OrderedJSON(parsing: element.source))?.jsonText ?? element.source
  }

  // model-router.service.ts:238
  private static func stringLeaves(_ value: OrderedJSON) -> [String] {
    switch value {
    case .string(let text): [text]
    case .array(let items): items.flatMap(stringLeaves)
    case .object(let object): object.entries.flatMap { stringLeaves($0.value) }
    case .null, .bool, .int, .double: []
    }
  }
}
