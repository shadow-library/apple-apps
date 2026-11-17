import ShadowCore

// apps/novel-forge-server/src/modules/refinement/chat-turn-trace.ts:48-49
private let toolLimit = 64
private let maxSources = 64

/// One lookup as a reply's trace names it: never the result.
struct TurnTraceSource: Equatable, Sendable {
  let tool: String
  let args: ChatTraceArgs
  let status: ChatTraceStatus

  // chat-turn-trace.ts:117; keyed by the arguments in key order, since a carried source comes back from a JSON object that keeps none
  fileprivate var key: String {
    "\(tool)\u{0}\(args.entries.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{0}"))"
  }

  var json: JSONValue {
    var args = [String: JSONValue]()
    for entry in self.args.entries {
      switch entry.value {
      case .text(let text): args[entry.key] = .string(text)
      case .count(let number): if let whole = Int64(exactly: number) { args[entry.key] = .int(whole) }
      }
    }
    return .object(["tool": .string(tool), "args": .object(args), "status": .string(status.rawValue)])
  }

  init(tool: String, args: ChatTraceArgs, status: ChatTraceStatus) {
    self.tool = tool
    self.args = args
    self.status = status
  }

  init?(json: JSONValue) {
    guard let fields = json.objectValue, let tool = fields["tool"]?.stringValue, let args = fields["args"]?.objectValue,
      let status = fields["status"]?.stringValue.flatMap(ChatTraceStatus.init(rawValue:))
    else { return nil }
    let entries = args.keys.sorted().compactMap { key -> ChatTraceArgs.Entry? in
      switch args[key] {
      case .string(let text)?: ChatTraceArgs.Entry(key: key, value: .text(text))
      case .int(let number)?: ChatTraceArgs.Entry(key: key, value: .count(Double(number)))
      default: nil
      }
    }
    self.init(tool: tool, args: ChatTraceArgs(entries: entries), status: status)
  }
}

/// Port of the reference's `TurnTraceCollector` (chat-turn-trace.ts:74-163): which sources a turn read, at most 64 and each once, and how long it read, thought,
/// wrote and saved, replaying the web turn reducer's clock. `now` is in milliseconds; a resumed turn carries the sources of the rounds it skips.
struct TurnTraceCollector: Sendable {
  private var sources: [TurnTraceSource] = []
  private let startedAt: Double
  private var running = 0
  private var waitingSince: Double?
  private var writingSince: Double?
  private var thoughtMs = 0.0
  private var replyAt: Double?
  private var changeAt: Double?
  private var written = false
  private var supersede = false

  init(at now: Double, carrying sources: [TurnTraceSource] = []) {
    startedAt = now
    waitingSince = now
    self.sources = Array(sources.prefix(maxSources))
  }

  var recorded: [TurnTraceSource] { sources }

  // chat-turn-trace.ts:91
  mutating func observe(_ event: ReplyStreamEvent, at now: Double) {
    switch event {
    case .delta: wrote(reply: true, at: now)
    case .change: wrote(reply: false, at: now)
    case .reset: reset(at: now)
    }
  }

  // chat-turn-trace.ts:108
  mutating func lookupStarted(at now: Double) {
    running += 1
    paused(at: now)
  }

  // chat-turn-trace.ts:113
  mutating func lookupSettled(tool: String, args: ChatTraceArgs, status: ChatTraceStatus, at now: Double) {
    running = max(0, running - 1)
    paused(at: now)
    let clippedTool = tool.jsLength > toolLimit ? "\(tool.jsSlice(0, toolLimit).jsTrimEnd())…" : tool
    let source = TurnTraceSource(tool: clippedTool, args: args, status: status)
    if let index = sources.firstIndex(where: { $0.key.jsEquals(source.key) }) {
      sources[index] = source
      return
    }
    guard sources.count < maxSources else { return }
    sources.append(source)
  }

  // chat-turn-trace.ts:123
  mutating func supersedeOnNextWrite() {
    supersede = written
  }

  // chat-turn-trace.ts:127
  func finish(at end: Double) -> JSONValue {
    let thinkMs = thoughtMs + (waitingSince.map { max(0, end - $0) } ?? 0)
    let firstWrite = [replyAt, changeAt].compactMap { $0 }.min() ?? end
    var timing: [String: JSONValue] = [
      "readMs": Self.elapsed(firstWrite - startedAt - thinkMs), "thinkMs": Self.elapsed(thinkMs), "workedMs": Self.elapsed(end - startedAt),
    ]
    if let replyAt { timing["writeMs"] = Self.elapsed((changeAt ?? end) - replyAt) }
    if let changeAt { timing["saveMs"] = Self.elapsed(end - changeAt) }
    return .object(["sources": .array(sources.map(\.json)), "timing": .object(timing)])
  }

  // chat-turn-trace.ts:71
  private static func elapsed(_ milliseconds: Double) -> JSONValue {
    .int(Int64(exactly: max(0, milliseconds).rounded()) ?? 0)
  }

  // chat-turn-trace.ts:138
  private mutating func paused(at now: Double) {
    writingSince = nil
    waitingSince = running > 0 ? nil : (waitingSince ?? now)
  }

  // chat-turn-trace.ts:143
  private mutating func wrote(reply: Bool, at now: Double) {
    if supersede { reset(at: now) }
    written = true
    if reply {
      replyAt = replyAt ?? now
    } else {
      changeAt = changeAt ?? now
    }
    guard writingSince == nil else { return }
    if let waitingSince { thoughtMs += max(0, now - waitingSince) }
    waitingSince = nil
    writingSince = now
  }

  // chat-turn-trace.ts:155
  private mutating func reset(at now: Double) {
    supersede = false
    guard written else { return }
    written = false
    paused(at: now)
    replyAt = nil
    changeAt = nil
  }
}
