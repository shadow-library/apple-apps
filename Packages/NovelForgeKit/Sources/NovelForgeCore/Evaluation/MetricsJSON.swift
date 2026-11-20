import Foundation
import ShadowText

extension OrderedJSON {
  static func number(_ value: Double) -> OrderedJSON {
    value.jsIsInteger && abs(value) < 9e15 ? .int(Int64(value)) : .double(value)
  }

  static func number(_ value: Int) -> OrderedJSON { .int(Int64(value)) }

  static func record(_ pairs: [(String, OrderedJSON)]) -> OrderedJSON {
    .object(OrderedJSONObject(pairs.map { (key: $0.0, value: $0.1) }))
  }

  static func strings(_ values: [String]) -> OrderedJSON { .array(values.map { .string($0) }) }

  static func optional(_ value: String?) -> OrderedJSON { value.map { .string($0) } ?? .null }
}

extension SentenceLengthMetrics {
  var json: OrderedJSON {
    .record([
      ("sentenceCount", .number(sentenceCount)), ("bandCount", .number(bandCount)), ("bandRate", .number(bandRate)),
      ("longestMonotonyRun", .number(longestMonotonyRun)), ("lengths", .array(lengths.map { .number($0) })),
    ])
  }
}

extension ReadabilityMetrics {
  var json: OrderedJSON {
    .record([
      ("words", .number(words)), ("sentenceCount", .number(sentenceCount)), ("paragraphCount", .number(paragraphCount)),
      ("averageSentenceWords", .number(averageSentenceWords)), ("longSentenceShare", .number(longSentenceShare)), ("longSentences", .strings(longSentences)),
      ("averageParagraphWords", .number(averageParagraphWords)), ("longParagraphs", .strings(longParagraphs)), ("readingGrade", .number(readingGrade)),
      ("ornateHits", .array(ornateHits.map { .record([("label", .string($0.label)), ("sentence", .string($0.sentence))]) })),
      ("ornateHitsPer1000Words", .number(ornateHitsPer1000Words)),
    ])
  }
}

extension NgramReport {
  var json: OrderedJSON {
    .record([
      (
        "sizes",
        .array(
          sizes.map {
            .record([
              ("n", .number($0.n)), ("totalOccurrences", .number($0.totalOccurrences)), ("repeatedOccurrences", .number($0.repeatedOccurrences)),
              ("repeatedRate", .number($0.repeatedRate)),
            ])
          })
      ),
      ("overallRepeatedRate", .number(overallRepeatedRate)),
    ])
  }
}

extension StockPhraseReport {
  var json: OrderedJSON {
    .record([("hits", .array(hits.map { .record([("label", .string($0.label)), ("count", .number($0.count))]) })), ("total", .number(total))])
  }
}

extension DialogueTagMetrics {
  var json: OrderedJSON {
    .record([
      ("totalTags", .number(totalTags)), ("saidAskedCount", .number(saidAskedCount)), ("alternativeCount", .number(alternativeCount)),
      ("saidAlternativeRate", .number(saidAlternativeRate)), ("tagsPer1000Words", .number(tagsPer1000Words)),
    ])
  }
}

extension ContractionRateReport {
  var json: OrderedJSON {
    .record([("contracted", .number(contracted)), ("expanded", .number(expanded)), ("rate", .number(rate))])
  }
}

extension EndingModeDistribution {
  var json: OrderedJSON {
    .record([
      ("counts", .record(counts.map { ($0.hookType, .number($0.count)) })), ("distinctCount", .number(distinctCount)), ("total", .number(total)),
    ])
  }
}

extension ResolvedWordTarget {
  var json: OrderedJSON { .record([("min", .number(min)), ("max", .number(max)), ("aim", .number(aim))]) }
}

extension WordCountSummary {
  var json: OrderedJSON {
    .record([
      ("chapters", .array(chapters.map { .record([("chapter", .number($0.chapter)), ("words", .number($0.words)), ("inTarget", .bool($0.inTarget))]) })),
      ("count", .number(count)), ("inTargetCount", .number(inTargetCount)), ("inTargetRate", .number(inTargetRate)), ("min", .number(min)),
      ("max", .number(max)), ("mean", .number(mean)), ("median", .number(median)),
    ])
  }
}

extension ChapterMetricsReport {
  var json: OrderedJSON {
    .record([
      ("chapter", .number(chapter)), ("words", .number(words)), ("inWordTarget", .bool(inWordTarget)), ("sentence", sentence.json),
      ("withinChapterNgrams", withinChapterNgrams.json), ("crossChapterNgrams", crossChapterNgrams.json), ("stockPhrases", stockPhrases.json),
      ("dialogueTags", dialogueTags.json), ("contractionRate", contractionRate.json), ("readability", readability.json), ("hookType", .optional(hookType)),
    ])
  }
}

extension DeterministicMetricsReport {
  var json: OrderedJSON {
    .record([("chapters", .array(chapters.map(\.json))), ("wordCountSummary", wordCountSummary.json), ("endingModeDistribution", endingModeDistribution.json)])
  }
}
