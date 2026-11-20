import ShadowText

private let underEighteen = "(?:[1-9]|1[0-7]|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen)"

func builtInPattern(_ source: String, flags: String = "") -> JSRegex {
  do {
    return try JSRegex(source, flags: flags)
  } catch {
    preconditionFailure("The built-in hard-line pattern \(source) is not a valid regular expression: \(error)")
  }
}

private func pattern(_ source: String) -> JSRegex {
  builtInPattern(source, flags: "i")
}

private func words(_ terms: String...) -> [JSRegex] {
  terms.map { pattern(#"\b(?:\#($0))\b"#) }
}

extension HardLineLexicon {
  // apps/novel-forge-server/src/modules/ai/hard-line.ts:50
  static let standard = HardLineLexicon(
    standalone: words("lolicon", "shotacon", "loli", "shota", "csam", "child porn(?:ography)?", "pedophilic", "paedophilic"),
    minor: words("child(?:ren|s)?", "minors", "under-?age", "pre-?teens?", "prepubescent", "pubescent")
      + words("toddlers?", "infants?", "schoolgirls?", "schoolboys?", "grade-?schoolers?", "middle-?schoolers?", "young teens?", "little (?:girl|boy)s?") + [
        pattern(#"\b\#(underEighteen)[- ]?(?:years?|yrs?)[- ]?old\b"#),
        pattern(#"\b(?:aged?|age of) \#(underEighteen)\b"#),
        pattern(#"\b(?:[1-9]|1[0-7])\s?yo\b"#),
      ],
    sexual: words(
      "sex",
      "sexual(?:ly|ised|ized|ise|ize)?",
      "sexy",
      "erotic(?:a|ally|ism)?",
      "orgasm(?:s|ic)?",
      "intercourse",
      "genital(?:s|ia)?",
      "fondl(?:e|ed|es|ing)",
      "molest(?:ed|er|ing|ation|s)?",
      "grop(?:e|ed|es|ing)",
      "made love|making love|make love",
      "porn(?:ographic|ography)?",
      "masturbat(?:e|ed|es|ing|ion)",
      "lewd"
    ),
    explicit: words(
      "sexual intercourse",
      "intercourse",
      "orgasm(?:s|ic)?",
      "genital(?:s|ia)?",
      "porn(?:ographic|ography)?",
      "masturbat(?:e|ed|es|ing|ion)",
      "erotic(?:a|ally|ism)?"
    )
  )
}

// apps/novel-forge-server/src/modules/ai/hard-line.ts:79
let hardLineSystemLine =
  "Absolute limit, whatever the story or the author asks: never write sexual content involving anyone under eighteen, and never sexualise anyone under eighteen. If the material calls for it, leave it out and write around it."
