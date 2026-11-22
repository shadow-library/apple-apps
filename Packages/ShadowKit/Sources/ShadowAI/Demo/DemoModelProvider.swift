import Foundation
import OSLog
import ShadowCore
import Synchronization

/// Answers every call from an app's `DemoScript` on the device: no network, no key, deterministic for a given order of calls. Each answer streams as words,
/// finishes with a reported cost of zero and is ledgered under `host`, so a demo call never counts against a spend cap and reads as a demo in the ledger.
public struct DemoModelProvider: ModelProvider {
  /// A reserved name that never resolves (RFC 2606), so nothing could reach a network even through a misplaced credential.
  public static let host = "demo.invalid"
  public static let model = "shadow-demo"
  /// About forty words a second, as a fast model streams.
  public static let readingPace = Duration.milliseconds(25)

  static let origin: URL = {
    guard let origin = URL(string: "https://\(host)") else { preconditionFailure("The demo origin is a valid URL.") }
    return origin
  }()

  private static let logger = Logger(category: "ShadowAI.Demo")

  private let script: DemoScript
  private let task: ModelTask?
  private let pace: Duration
  private let clock: any Clock<Duration>
  private let turns: DemoTurns

  /// `pace` is the pause before each word after the first; `.zero` streams the whole answer at once.
  public init(script: DemoScript, pace: Duration = readingPace, clock: any Clock<Duration> = ContinuousClock()) {
    self.init(script: script, task: nil, pace: pace, clock: clock, turns: DemoTurns())
  }

  private init(script: DemoScript, task: ModelTask?, pace: Duration, clock: any Clock<Duration>, turns: DemoTurns) {
    self.script = script
    self.task = task
    self.pace = pace
    self.clock = clock
    self.turns = turns
  }

  /// The provider a route for `task` calls; it shares this one's place in each rule's replies.
  public func answering(_ task: ModelTask) -> DemoModelProvider {
    DemoModelProvider(script: script, task: task, pace: pace, clock: clock, turns: turns)
  }

  public func stream(_ request: ModelRequest) -> ModelStream {
    ModelStream { continuation throws(ModelError) in
      let answer = self.answer(try request.validated())
      try continuation.yield(.started(requestID: nil, generationID: nil))
      for (index, word) in Self.words(of: answer).enumerated() {
        if index > 0, pace > .zero {
          do {
            try await clock.sleep(for: pace)
          } catch {
            throw .cancelled
          }
        }
        try continuation.yield(.textDelta(word))
      }
      try continuation.yield(.finished(usage: .zero, reportedCost: .zero, stop: .endTurn))
    }
  }

  public func validate(_ credential: ProviderCredential) async throws(ModelError) -> CredentialStatus {
    throw .invalidRequest("The demo model takes no key.")
  }

  public func models() async throws(ModelError) -> [RemoteModel] {
    [RemoteModel(id: Self.model, name: "Demo", supportsJSONSchema: false, inputPrice: .zero, outputPrice: .zero)]
  }

  func answer(_ request: ModelRequest) -> String {
    let ask = DemoAsk(request)
    let reply = reply(to: ask)
    guard let structure = ask.structure else { return reply.map(Self.text) ?? script.fallback }
    if case .json(let value)? = reply, DemoSample.accepts(structure.schema, value) { return StructuredSchema.jsonText(value) }
    if reply != nil {
      Self.logger.notice("A demo reply does not satisfy its schema; answering with a sample schema=\(structure.name, privacy: .public)")
    }
    guard let sample = DemoSample.value(for: structure.schema, text: script.fallback) else {
      Self.logger.error("No sample satisfies a demo call's schema schema=\(structure.name, privacy: .public)")
      return script.fallback
    }
    return StructuredSchema.jsonText(sample)
  }

  private func reply(to ask: DemoAsk) -> DemoReply? {
    guard let index = script.rules.firstIndex(where: { !$0.replies.isEmpty && ask.isMatched(by: $0.match, task: task) }) else { return nil }
    let replies = script.rules[index].replies
    return replies[turns.take(rule: index) % replies.count]
  }

  private static func text(_ reply: DemoReply) -> String {
    switch reply {
    case .text(let text): text
    case .json(let value): StructuredSchema.jsonText(value)
    }
  }

  /// Splits before each run of whitespace, so the words join back to the answer exactly.
  static func words(of text: String) -> [String] {
    var words: [String] = []
    var current = ""
    var previousIsWhitespace = false
    for character in text {
      if character.isWhitespace, !previousIsWhitespace, !current.isEmpty {
        words.append(current)
        current = ""
      }
      current.append(character)
      previousIsWhitespace = character.isWhitespace
    }
    if !current.isEmpty { words.append(current) }
    return words
  }
}

/// How many calls each rule has answered, shared by every route's copy of one provider.
private final class DemoTurns: Sendable {
  private let counts = Mutex<[Int: Int]>([:])

  func take(rule: Int) -> Int {
    counts.withLock { counts in
      defer { counts[rule, default: 0] += 1 }
      return counts[rule, default: 0]
    }
  }
}

/// What a request asks, as a rule reads it: a native schema from the format, otherwise one `StructuredPrompt` appended to the user's last message, or to
/// the one before it when the last is a repair re-ask.
struct DemoAsk {
  let prompt: String
  let structure: (name: String, schema: JSONValue)?

  init(_ request: ModelRequest) {
    let userTexts = request.messages.filter { $0.role == .user }.map(\.text)
    if case .json(let name, let schema) = request.format {
      prompt = userTexts.last ?? ""
      structure = (name, schema)
    } else if let instructed = Self.instructed(userTexts) {
      prompt = instructed.prompt
      structure = (instructed.name, instructed.schema)
    } else {
      prompt = userTexts.last ?? ""
      structure = nil
    }
  }

  private static func instructed(_ userTexts: [String]) -> (prompt: String, name: String, schema: JSONValue)? {
    guard let last = userTexts.last else { return nil }
    guard StructuredPrompt.isRepairRequest(last), userTexts.count > 1 else { return StructuredPrompt.schemaInstruction(ending: last) }
    return StructuredPrompt.schemaInstruction(ending: userTexts[userTexts.count - 2])
  }

  func isMatched(by match: DemoMatch, task: ModelTask?) -> Bool {
    if let wanted = match.task, wanted != task { return false }
    if let wanted = match.schema, wanted != structure?.name { return false }
    if let phrase = match.phrase, prompt.range(of: phrase, options: .caseInsensitive) == nil { return false }
    return true
  }
}
