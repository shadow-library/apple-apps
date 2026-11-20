import Foundation
import ShadowText

public enum LibraryLimits {
  public static let titleCharactersOnCreate = 255
  public static let titleCharactersOnEdit = 500
  public static let notesCharacters = 100_000
  public static let notesWords = 10_000
}

// apps/novel-forge-web/src/lib/start-novel.ts:23,38,43: both counts are taken on the trimmed text, and the form submits it trimmed, so trailing whitespace never blocks a valid entry
public enum LibraryCounting {
  public static func words(in notes: String) -> Int {
    ProseMetrics.countWords(notes)
  }

  public static func characters(in text: String) -> Int {
    text.jsTrim().unicodeScalars.count
  }
}
