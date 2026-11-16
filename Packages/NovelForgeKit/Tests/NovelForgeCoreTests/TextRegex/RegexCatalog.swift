import ShadowTestSupport

@testable import NovelForgeCore

struct RegexCase: Sendable, CustomStringConvertible {
  let entry: Int
  let location: String
  let source: String
  let flags: String
  let siteTemplate: String
  let vocabulary: [String]

  var file: String { String(location.prefix { $0 != ":" }) }

  var description: String { "\(location) /\(source)/\(flags)" }
}

enum RegexCatalog {
  struct Entry: Decodable {
    let location: String
    let kind: String
    let source: String?
    let flags: String?
    let resolved: String?
  }

  private struct Collected: Decodable {
    let regexes: [Entry]
  }

  static let files = [
    "writer-disclosure-policy.ts", "reveal-term.ts", "term-text.ts", "hard-line.ts", "mechanical-check.ts", "deterministic-metrics.ts", "chapter-prose.ts",
    "write-policy.ts", "negation-echo.ts", "idea-id.ts", "prose-paragraphs.ts", "passage-anchor.ts", "passage-context.ts",
  ]

  static let hardLineTerms = [
    "lolicon", "shotacon", "loli", "shota", "csam", "child porn(?:ography)?", "pedophilic", "paedophilic", "child(?:ren|s)?", "minors", "under-?age", "pre-?teens?",
    "prepubescent", "pubescent", "toddlers?", "infants?", "schoolgirls?", "schoolboys?", "grade-?schoolers?", "middle-?schoolers?", "young teens?", "little (?:girl|boy)s?",
    "sex", "sexual(?:ly|ised|ized|ise|ize)?", "sexy", "erotic(?:a|ally|ism)?", "orgasm(?:s|ic)?", "intercourse", "genital(?:s|ia)?", "fondl(?:e|ed|es|ing)",
    "molest(?:ed|er|ing|ation|s)?", "grop(?:e|ed|es|ing)", "made love|making love|make love", "porn(?:ographic|ography)?", "masturbat(?:e|ed|es|ing|ion)", "lewd",
    "sexual intercourse",
  ]

  static let dialogueTagVerbs = [
    "said", "asked", "exclaimed", "growled", "whispered", "shouted", "muttered", "hissed", "snapped", "murmured", "replied", "answered", "demanded", "insisted",
    "breathed", "gasped", "sighed", "warned", "protested", "agreed", "countered", "continued", "added", "interrupted", "laughed",
  ]

  static let contractionPairs = [
    ("don't", "do not"), ("doesn't", "does not"), ("didn't", "did not"), ("can't", "cannot"), ("couldn't", "could not"), ("won't", "will not"),
    ("wouldn't", "would not"), ("shouldn't", "should not"), ("isn't", "is not"), ("aren't", "are not"), ("wasn't", "was not"), ("weren't", "were not"),
    ("hasn't", "has not"), ("haven't", "have not"), ("hadn't", "had not"), ("I'm", "I am"), ("you're", "you are"), ("he's", "he is"), ("she's", "she is"),
    ("it's", "it is"), ("we're", "we are"), ("they're", "they are"), ("I've", "I have"), ("you've", "you have"), ("we've", "we have"), ("they've", "they have"),
    ("I'll", "I will"), ("you'll", "you will"), ("he'll", "he will"), ("she'll", "she will"), ("we'll", "we will"), ("they'll", "they will"), ("that's", "that is"),
    ("there's", "there is"), ("let's", "let us"),
  ]

  static let termWords = [
    "the", "Heir", "secret", "naïve", "Ödön", "a.b", "(x)", "$5", "c++", "x|y", "[note]", "{k}", "^up", "back\\slash", "don’t", "it's", "“quoted”", "—", "well-known",
    "中文", "かな", "ſtraße", "Kelvin", "**bold**", "_it_", "end.", "a?", "*", "Straße", "ǅemal", "İstanbul", "😀ok",
  ]

  private static let siteTemplates: [String: String] = [
    "writer-disclosure-policy.ts:55": "", "writer-disclosure-policy.ts:56": "", "writer-disclosure-policy.ts:57": "", "term-text.ts:2": "\\$&",
    "hard-line.ts:134": " ", "mechanical-check.ts:70": " ", "mechanical-check.ts:122": " ", "deterministic-metrics.ts:219": " ", "deterministic-metrics.ts:316": "",
    "deterministic-metrics.ts:336": " ", "deterministic-metrics.ts:343": "", "deterministic-metrics.ts:346": "", "deterministic-metrics.ts:389": "",
    "deterministic-metrics.ts:516": "['’]", "write-policy.ts:173": " ", "write-policy.ts:187": "'", "write-policy.ts:188": "\"", "write-policy.ts:189": "-",
    "write-policy.ts:190": " ", "write-policy.ts:195": "", "write-policy.ts:215": "", "negation-echo.ts:140": "", "negation-echo.ts:162": "'", "negation-echo.ts:165": "",
    "idea-id.ts:41": " ", "passage-context.ts:108": "\n   ",
  ]

  static func entries() throws -> [Entry] {
    try ReferenceFixture.decode(Collected.self, from: "text/reference-regexes.json").regexes
  }

  static func cases() throws -> [RegexCase] {
    var generator = SeededGenerator(seed: 0xD03)
    return try entries().enumerated().flatMap { try instances(of: $0.element, entry: $0.offset, using: &generator) }
  }

  static func shortLocation(_ location: String) -> String {
    String(location.split(separator: "/").last ?? "")
  }

  private static func instances(of entry: Entry, entry index: Int, using generator: inout SeededGenerator) throws -> [RegexCase] {
    let location = shortLocation(entry.location)
    let template = siteTemplates[location] ?? "#"
    func make(_ source: String, _ flags: String, _ vocabulary: [String] = []) -> RegexCase {
      RegexCase(entry: index, location: entry.location, source: source, flags: flags, siteTemplate: template, vocabulary: vocabulary + words(in: source))
    }
    if entry.kind == "literal", let source = entry.source { return [make(source, entry.flags ?? "")] }
    if let resolved = entry.resolved, !resolved.contains("${") { return [make(resolved, entry.flags ?? "")] }
    switch location {
    case "writer-disclosure-policy.ts:89":
      return try (0..<6).map { _ in
        let passage = seededPassage(using: &generator)
        return make(try PassagePattern.source(for: passage), "giu", passage.split(separator: " ").map(String.init))
      }
    case "writer-disclosure-policy.ts:100":
      return ["fact:heir_secret", "fact:a.b*c", "the_[x]_key", "fact:Ödön_ß", "fact:$1(2)|3", "fact:k_ſ"].map {
        make("(?<![\\p{L}\\p{N}_])\(JSRegex.escape($0))(?![\\p{L}\\p{N}_])", "giu", [$0])
      }
    case "reveal-term.ts:15":
      let terms = ["Will", "the heir", "kelvin", "a+b?", "Ægir", "naïve.", "中文名", "(secret)", "x|y", "ſtar", "strasse"]
      return try terms.enumerated().map { offset, term in
        let flags = (offset.isMultiple(of: 2) ? "g" : "") + (try JSRegex("\\p{Lu}", flags: "u").test(term) ? "u" : "iu")
        return make("(?<![\\p{L}\\p{N}_])\(JSRegex.escape(term))(?![\\p{L}\\p{N}_])", flags, [term])
      }
    case "hard-line.ts:45":
      return generator.shuffled(hardLineTerms).prefix(12).map { make("\\b(?:\($0))\\b", "i") }
    case "deterministic-metrics.ts:477":
      let verbs = dialogueTagVerbs.joined(separator: "|")
      return [make("[\"”]\\s*,?\\s*(?:[A-Z][a-z]+(?:\\s[A-Z][a-z]+)?\\s)?(\(verbs))\\b", "gi", ["Mary Ann", "Tom"])]
    case "deterministic-metrics.ts:516":
      return try generator.shuffled(contractionPairs).prefix(10).map { pair in
        make("\\b\(pair.0.jsReplace(try JSRegex("'", flags: "g"), "['’]"))\\b", "gi", [pair.0, pair.1, pair.0.replacing("'", with: "’")])
      }
    case "deterministic-metrics.ts:517":
      return generator.shuffled(contractionPairs).prefix(10).map { make("\\b\($0.1)\\b", "gi", [$0.0, $0.1]) }
    case "chapter-prose.ts:14", "prose-paragraphs.ts:81":
      return ["```", "````", "~~~", "~~~~~~", "`````````"].map { marker in
        make("^ {0,3}\(marker.hasPrefix("`") ? "`" : "~"){\(marker.jsLength),}[ \\t]*$", "", [marker, "```", "~~~~"])
      }
    default:
      throw Mismatch(description: "no instances for the run-time pattern at \(entry.location)")
    }
  }

  private static func seededPassage(using generator: inout SeededGenerator) -> String {
    let words = (0..<generator.int(in: 2...6)).map { _ in generator.pick(from: termWords) }
    let prefix = generator.pick(from: ["", "", "- ", "1. ", "## "])
    let suffix = generator.pick(from: ["", ".", "!?", " …"])
    return prefix + words.joined(separator: generator.pick(from: [" ", " ", "\n", "  "])) + suffix
  }

  private static func words(in source: String) -> [String] {
    var words: [String] = []
    var current = ""
    var previous: Character = " "
    for character in source {
      if character.isLetter, previous != "\\" {
        current.append(character)
      } else {
        if current.count > 1 { words.append(current) }
        current = ""
      }
      previous = character
    }
    if current.count > 1 { words.append(current) }
    return words
  }
}

enum PassagePattern {
  static let referenceBuilder = """
    (text) => {
      const escapeRegExp = term => term.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      const EMPHASIS_MARK = '[*_]{0,2}';
      const WORD_GAP = `${EMPHASIS_MARK}\\\\s+${EMPHASIS_MARK}`;
      const CHARACTER_CLASSES = [[/["“”„«»]/u, '["“”„«»]'], [/['’‘`]/u, "['’‘`]"], [/[-‐‑–—]/u, '[-‐‑–—]']];
      const charPattern = char => CHARACTER_CLASSES.find(([matches]) => matches.test(char))?.[1] ?? escapeRegExp(char);
      const trimmed = text.replace(/^\\s*(?:[-*+>]|\\d+[.)]|#{1,6})\\s+/, '').replace(/\\*+|_{2,}|`/g, '').replace(/[\\s.!?;:,…。！？]+$/u, '').trim();
      const body = trimmed.split(/\\s+/).map(word => [...word].map(charPattern).join('')).join(WORD_GAP);
      return `(?<![\\\\p{L}\\\\p{N}])${EMPHASIS_MARK}${body}${EMPHASIS_MARK}(?![\\\\p{L}\\\\p{N}])`;
    }
    """

  static func source(for text: String) throws -> String {
    let characterClasses = [
      (try JSRegex("[\"“”„«»]", flags: "u"), "[\"“”„«»]"), (try JSRegex("['’‘`]", flags: "u"), "['’‘`]"), (try JSRegex("[-‐‑–—]", flags: "u"), "[-‐‑–—]"),
    ]
    let emphasisMark = "[*_]{0,2}"
    let wordGap = "\(emphasisMark)\\s+\(emphasisMark)"
    let trimmed =
      text
      .jsReplace(try JSRegex(#"^\s*(?:[-*+>]|\d+[.)]|#{1,6})\s+"#), "")
      .jsReplace(try JSRegex(#"\*+|_{2,}|`"#, flags: "g"), "")
      .jsReplace(try JSRegex(#"[\s.!?;:,…。！？]+$"#, flags: "u"), "")
      .jsTrim()
    let body = trimmed.jsSplit(try JSRegex(#"\s+"#))
      .map { word in word.jsCodePoints.map { char in characterClasses.first { $0.0.test(char) }?.1 ?? JSRegex.escape(char) }.joined() }
      .joined(separator: wordGap)
    return "(?<![\\p{L}\\p{N}])\(emphasisMark)\(body)\(emphasisMark)(?![\\p{L}\\p{N}])"
  }
}
