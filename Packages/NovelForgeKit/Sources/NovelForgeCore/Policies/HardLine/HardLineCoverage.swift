import Foundation
import NaturalLanguage
import ShadowStore

/// The languages the hard-line lexicon is written in. Unrestricted writing is offered only for a novel in one of them: English at launch.
public enum HardLineCoverage {
  static let languages: Set<NLLanguage> = [.english]
  /// Below these the recogniser guesses: a one-word title reads as English at 0.29, a mixed sample still names a top language.
  static let minimumWords = 12
  static let minimumConfidence = 0.9

  public static func covers(_ language: NLLanguage?) -> Bool {
    language.map(languages.contains) ?? false
  }

  /// Read from the novel's opening prose, else its lore, and only before it has either from its own description; a sample too short or too mixed to tell
  /// is not covered.
  public static func covers(novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> Bool {
    covers(try language(novel: novel, in: transaction))
  }

  static func language(novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> NLLanguage? {
    let indexed = try transaction.query { database in try RetrievalVectors.sample(novel: novel, in: database) }
    if indexed.contains(where: { !$0.isWhitespace }) { return language(of: indexed) }
    guard let record = try NovelRecord.read(id: novel, in: transaction).entry?.record else { return nil }
    return language(of: description(of: record))
  }

  static func language(of sample: String) -> NLLanguage? {
    guard sample.split(whereSeparator: \.isWhitespace).count >= minimumWords else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(sample)
    guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= minimumConfidence else { return nil }
    return language
  }

  /// The novel's prose-like fields; its name and title are left out, since a title alone says little about the language.
  static func description(of novel: NovelRecord) -> String {
    let fields: [String?] = [
      novel.brief, novel.premise, novel.theme, novel.themes?.joined(separator: ", "), novel.protagonist, novel.opposition, novel.readerPromise,
      novel.endingQuestion, novel.ending, novel.writingStyle,
    ]
    return fields.compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n")
  }
}
