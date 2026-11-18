import Foundation

private let wordCharacters = #"[\p{L}\p{N}_]"#

// Native-only: the reference lexicon is fixed and has no per-novel terms.
enum MinorAge {
  static let adulthood = 18

  static func isMinor(_ age: Int?) -> Bool {
    guard let age, age >= 0 else { return false }
    return age < adulthood
  }
}

private let segmentBreakCharacters = builtInPattern(#"[.!?;\n]+"#)
private let minimumFragmentLength = 2
private let honorifics: Set<String> = ["dr", "mr", "mrs", "ms", "mx", "st", "sr", "jr", "mt", "sir", "lady"]
private let breakAndSpace = CharacterSet(charactersIn: ".!?;").union(.whitespacesAndNewlines)
private let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}"]

func minorNames(in characters: [EntityRecord]) -> [String] {
  var seen = Set<String>()
  return characters.compactMap { record -> String? in
    guard record.type == .known(.character), MinorAge.isMinor(record.age) else { return nil }
    return record.name
  }.flatMap(screenableTerms).filter { seen.insert($0.precomposedStringWithCanonicalMapping.lowercased()).inserted }
}

private func screenableTerms(of name: String) -> [String] {
  let core = name.trimmingCharacters(in: breakAndSpace)
  guard !core.isEmpty else { return [] }
  guard core.hasSuffix(")"), let open = core.lastIndex(of: "(") else { return whole(core) }
  return screenableTerms(of: String(core[..<open])) + whole(core)
}

private func whole(_ core: String) -> [String] {
  guard segmentBreakCharacters.test(core) else { return [core] }
  let fragments = core.jsSplit(segmentBreakCharacters).map { $0.trimmingCharacters(in: breakAndSpace) }.filter { $0.count >= minimumFragmentLength }
  let names = fragments.filter { !honorifics.contains($0.lowercased()) }
  return names.isEmpty ? fragments : names
}

private func tokenPattern(_ token: String) -> String {
  token.map { apostrophes.contains($0) ? "['\u{2019}\u{2018}\u{02BC}]" : JSRegex.escape(String($0)) }.joined()
}

private func namePattern(_ name: String) -> JSRegex {
  let forms = [name.precomposedStringWithCanonicalMapping, name.decomposedStringWithCanonicalMapping]
  let distinct = forms.enumerated().filter { index, form in !forms[..<index].contains { $0.unicodeScalars.elementsEqual(form.unicodeScalars) } }.map(\.element)
  let alternatives = distinct.map { form in
    form.split(whereSeparator: \.isWhitespace).map { tokenPattern(String($0)) }.joined(separator: #"\s+"#)
  }
  return builtInPattern("(?<!\(wordCharacters))(?:\(alternatives.joined(separator: "|")))(?!\(wordCharacters))", flags: "iu")
}

extension HardLineLexicon {
  func adding(minorNames names: [String]) -> HardLineLexicon {
    var lexicon = self
    lexicon.minor += names.map(namePattern)
    return lexicon
  }

  static func standard(withMinorsIn characters: [EntityRecord]) -> HardLineLexicon {
    HardLineLexicon.standard.adding(minorNames: minorNames(in: characters))
  }
}
