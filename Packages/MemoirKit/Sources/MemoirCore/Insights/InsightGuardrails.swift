import ShadowText

public enum GuardrailViolation: String, CaseIterable, Sendable, Hashable {
  case verbatimQuote = "verbatim_quote"
  case identityAssertion = "identity_assertion"
  case shameCopy = "shame_copy"
  case mechanicMutation = "mechanic_mutation"
}

public struct GuardrailInput: Sendable, Equatable {
  public var question: String
  /// Every most-sensitive free text the assembly put in front of the model; the quote check compares against exactly these.
  public var sensitiveSources: [String]
  public var allowedQuestIDs: [String]
  public var draft: InsightDraft

  public init(question: String, sensitiveSources: [String], allowedQuestIDs: [String], draft: InsightDraft) {
    self.question = question
    self.sensitiveSources = sensitiveSources
    self.allowedQuestIDs = allowedQuestIDs
    self.draft = draft
  }
}

/// A crisis carries no violation, so nothing can mark the event in the owner's data.
public enum GuardrailOutcome: Sendable, Equatable {
  case passed(InsightDraft)
  case sanitized(InsightDraft, violations: [GuardrailViolation])
  case crisis(InsightDraft)
  case blocked([GuardrailViolation])
}

/// The reference's output post-filter, ported on `JSRegex` with its patterns verbatim.
// apps/memoir-server/src/modules/ai-worker/guardrails.ts
public enum InsightGuardrails {
  public static let allowedSuggestionKinds = InsightSuggestionKind.allCases.map(\.rawValue)

  public static let crisisResponseAnswer = [
    "I'm not able to answer this one as a coaching question, and I don't want to.",
    "If you are thinking about harming yourself, please talk to someone who can help right now:",
    "• US & Canada — call or text 988 (Suicide & Crisis Lifeline)",
    "• UK & Ireland — call 116 123 (Samaritans)",
    "• India — call 9152987821 (iCall)",
    "• Anywhere else — findahelpline.com lists a free, confidential line for your country",
    "If you are in immediate danger, please contact your local emergency number.",
  ].joined(separator: "\n")

  private static let minimumQuoteWords = 7
  private static let minimumShortSourceWords = 4

  private static let identityLabels = [
    "lazy", "depressed", "anxious", "procrastinator", "failure", "quitter", "undisciplined", "addict", "addicted", "broken", "hopeless", "weak", "unmotivated",
    "loser", "slob", "bad person", "burnout case",
  ].joined(separator: "|")

  private static let clinicalLabels = ["depression", "anxiety disorder", "adhd", "add", "bipolar disorder", "ocd", "burnout", "an eating disorder", "insomnia disorder"]
    .joined(separator: "|")

  private static let identityPatterns = [
    pattern(
      #"\byou(?:'re| are| were| have been| seem| sound| always seem)\s+(?:just |simply |so |really |such |clearly |probably |likely |a bit |kind of )*(?:a |an |the )?(?:\#(identityLabels))\b"#
    ),
    pattern(#"\byou (?:have|had|suffer from|struggle with|are dealing with|are experiencing)\s+(?:clinical |chronic |mild |severe )*(?:\#(clinicalLabels))\b"#),
    pattern(#"\bdiagnos(?:is|ed|e|able)\b"#),
    pattern(#"\bthis (?:is|looks like|sounds like) (?:clinical|textbook) \w+"#),
    pattern(#"\byou(?:'re| are) (?:the (?:kind|type) of person|someone) who\b"#),
  ]

  private static let shamePatterns = [
    pattern(#"\byou failed (?:again|yet again)\b"#),
    pattern(#"\byou should be ashamed\b"#),
    pattern(#"\b(?:that's|this is) pathetic\b"#),
    pattern(#"\bno excuse\b"#),
    pattern(#"\bstop being (?:lazy|weak|so soft)\b"#),
    pattern(#"\byou always (?:give up|quit|let yourself down)\b"#),
    pattern(#"\bdisappointing\b"#),
  ]

  private static let crisisPatterns = [
    pattern(#"\bkill(?:ing)? myself\b"#),
    pattern(#"\bsuicid(?:e|al)\b"#),
    pattern(#"\bend(?:ing)? (?:it all|my life)\b"#),
    pattern(#"\btake my own life\b"#),
    pattern(#"\bwant to die\b"#),
    pattern(#"\bbetter off dead\b"#),
    pattern(#"\bno reason to (?:live|go on)\b"#),
    pattern(#"\bself[- ]harm\b"#),
    pattern(#"\b(?:hurt|harm|cut) (?:myself|my self)\b"#),
  ]

  /// A claim that the AI changed game state itself; nothing on this path can, so the claim would be false.
  private static let mechanicMutationPatterns = [
    pattern(#"\bI(?:'ve| have)? ?(?:already )?(?:updated|changed|adjusted|rescheduled|set|moved|paused|deleted|completed|awarded|granted|unlocked|applied)\b"#),
    pattern(#"\b(?:I|we) (?:have )?(?:added|removed) (?:\d+ )?(?:xp|coins?|hp|crown)\b"#),
    pattern(#"\byour (?:quest|xp|coins|streak|level|hp) (?:has|have) been (?:updated|changed|adjusted|awarded|reset)\b"#),
  ]

  private static let nonWordRun = builtIn(#"[^a-z0-9]+"#, flags: "g")

  /// Crisis is checked first and replaces the draft entirely.
  public static func apply(_ input: GuardrailInput) -> GuardrailOutcome {
    let output = input.draft.text
    if indicatesCrisis(input.question) || input.sensitiveSources.contains(where: indicatesCrisis) || indicatesCrisis(output) {
      return .crisis(InsightDraft(answer: crisisResponseAnswer))
    }
    var violations: [GuardrailViolation] = []
    if findVerbatimQuote(in: output, sources: input.sensitiveSources) != nil { violations.append(.verbatimQuote) }
    if identityPatterns.contains(where: { $0.test(output) }) { violations.append(.identityAssertion) }
    if shamePatterns.contains(where: { $0.test(output) }) { violations.append(.shameCopy) }
    let claimsMutation = mechanicMutationPatterns.contains { pattern in pattern.test(input.draft.answer) || input.draft.patterns.contains(where: pattern.test) }
    if claimsMutation { violations.append(.mechanicMutation) }
    guard violations.isEmpty else { return .blocked(violations) }
    let suggestions = input.draft.suggestions.filter { isApplicable($0, allowedQuestIDs: input.allowedQuestIDs) }
    guard suggestions.count != input.draft.suggestions.count else { return .passed(input.draft) }
    var sanitized = input.draft
    sanitized.suggestions = suggestions
    return .sanitized(sanitized, violations: [.mechanicMutation])
  }

  /// A run of the owner's own words reproduced unchanged, matched on seven-word shingles so a paraphrase passes; a source of four to seven words is
  /// compared whole, and a shorter one never counts.
  public static func findVerbatimQuote(in output: String, sources: [String]) -> String? {
    let haystack = NormalizedWords(normalized(output))
    guard !haystack.words.isEmpty else { return nil }
    for source in sources {
      let words = normalized(source).jsSplit(" ").filter { !$0.isEmpty }
      guard words.count >= minimumShortSourceWords else { continue }
      if words.count <= minimumQuoteWords {
        if haystack.contains(words[...]) { return words.joined(separator: " ") }
        continue
      }
      for start in 0...(words.count - minimumQuoteWords) {
        let shingle = words[start..<(start + minimumQuoteWords)]
        if haystack.contains(shingle) { return shingle.joined(separator: " ") }
      }
    }
    return nil
  }

  /// After lowercasing, every run outside `a-z0-9` is one space, so what remains is ASCII.
  static func normalized(_ text: String) -> String {
    text.jsToLowerCase().jsReplace(nonWordRun, " ").jsTrim()
  }

  static func indicatesCrisis(_ text: String) -> Bool {
    crisisPatterns.contains { $0.test(text) }
  }

  private static func isApplicable(_ suggestion: DraftSuggestion, allowedQuestIDs: [String]) -> Bool {
    guard case .string(let kind)? = suggestion.kind, allowedSuggestionKinds.contains(where: { $0.jsEquals(kind) }) else { return false }
    let questID = suggestion.questID.map(JSCoercion.string) ?? "undefined"
    guard allowedQuestIDs.contains(where: { $0.jsEquals(questID) }) else { return false }
    let text = suggestion.textOrEmpty
    return !mechanicMutationPatterns.contains { $0.test(text) }
  }

  private static func pattern(_ source: String) -> JSRegex {
    builtIn(source, flags: "i")
  }

  private static func builtIn(_ source: String, flags: String) -> JSRegex {
    do {
      return try JSRegex(source, flags: flags)
    } catch {
      preconditionFailure("The guardrail pattern \(source) is not a valid regular expression: \(error)")
    }
  }
}

/// Normalized text is ASCII words joined by single spaces, so a run of three or more words occurs as a substring exactly when its inner words are
/// consecutive words of the text, its first word ends the word before them and its last word starts the word after: `includes` without a scan per run.
struct NormalizedWords {
  let words: [String]
  private let positions: [String: [Int]]

  init(_ normalized: String) {
    words = normalized.isEmpty ? [] : normalized.jsSplit(" ")
    var positions: [String: [Int]] = [:]
    for (index, word) in words.enumerated() { positions[word, default: []].append(index) }
    self.positions = positions
  }

  func contains(_ run: ArraySlice<String>) -> Bool {
    precondition(run.count >= 3, "a run of fewer than three words is never looked up")
    let run = Array(run)
    for inner in positions[run[1]] ?? [] {
      let first = inner - 1
      guard first >= 0, first + run.count <= words.count, words[first].hasSuffix(run[0]) else { continue }
      guard (1..<(run.count - 1)).allSatisfy({ words[first + $0] == run[$0] }), words[first + run.count - 1].hasPrefix(run[run.count - 1]) else { continue }
      return true
    }
    return false
  }
}
