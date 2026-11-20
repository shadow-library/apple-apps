import Foundation
import ShadowTestSupport

@testable import ShadowText

struct RegexInputs {
  private indirect enum Shape {
    case character(UInt32)
    case any
    case set(JSRegexCharacterSet, JSRegexCompiledSet)
    case sequence([Shape])
    case alternation([Shape])
    case empty
    case repetition(Shape, min: Int, max: Int)
  }

  private static let lookalikes: [UInt32: [UInt32]] = [
    0x73: [0x017F, 0x53], 0x53: [0x017F], 0x6B: [0x212A, 0x4B], 0x4B: [0x212A], 0x69: [0x0130, 0x0131], 0x49: [0x0131, 0x0130], 0xDF: [0x1E9E], 0x3C3: [0x3C2, 0x3A3],
  ]

  private let root: Shape
  private let mode: JSRegexMode
  private let vocabulary: [String]
  private let pool: [[UInt16]]
  private let anchoredAtStart: Bool
  private let anchoredAtEnd: Bool

  init(_ regexCase: RegexCase) throws {
    let unicode = regexCase.flags.contains("u")
    var parser = JSRegexParser(source: regexCase.source, unicode: unicode)
    let tree = try parser.parse()
    let mode = JSRegexMode(unicode: unicode, ignoreCase: regexCase.flags.contains("i"))
    self.mode = mode
    root = Self.shape(of: tree, mode: mode)
    vocabulary = regexCase.vocabulary.isEmpty ? ["word"] : regexCase.vocabulary
    let literals = regexCase.source.unicodeScalars.filter { !$0.properties.isAlphabetic }.map { String($0) }
    pool = (TextSamples.pieces + literals + vocabulary.flatMap(\.jsCodePoints) + ["a", "e", "t", "y", "Q", "3", "_", "\u{10400}"]).map(\.jsCodeUnits)
    anchoredAtStart = tree.isAnchoredAtStart
    anchoredAtEnd = regexCase.source.hasSuffix("$") || regexCase.source.contains("$|")
  }

  func input(using generator: inout SeededGenerator) -> String {
    if generator.chance(anchoredAtStart && anchoredAtEnd ? 0.4 : 0.2) { return JSText.string(fromCodeUnits: sample(root, using: &generator)) }
    var units: [UInt16] = []
    let segments = generator.int(in: 1...5)
    for index in 0..<segments {
      if index > 0 { units += generator.pick(from: ["", " ", " ", "\n", "\t", "\u{2028}", "\u{A0}", "\u{FEFF}", "\r\n", "  "]).jsCodeUnits }
      let anchoredHere = (index == 0 && anchoredAtStart) || (index == segments - 1 && anchoredAtEnd)
      units += segment(forceSample: anchoredHere && generator.chance(0.6), using: &generator)
    }
    return JSText.string(fromCodeUnits: units)
  }

  private func segment(forceSample: Bool, using generator: inout SeededGenerator) -> [UInt16] {
    if forceSample { return sample(root, using: &generator) }
    switch generator.int(in: 0...19) {
    case 0...7: return sample(root, using: &generator)
    case 8...10: return mutated(sample(root, using: &generator), using: &generator)
    case 11...13: return cased(generator.pick(from: vocabulary).jsCodeUnits, using: &generator)
    case 14...16: return (0..<generator.int(in: 1...4)).flatMap { _ in generator.pick(from: pool) }
    case 17: return generator.pick(from: TextSamples.astral).jsCodeUnits + sample(root, using: &generator) + generator.pick(from: TextSamples.astral).jsCodeUnits
    case 18: return generator.pick(from: TextSamples.whitespace).jsCodeUnits
    default:
      let piece = generator.chance(0.5) ? sample(root, using: &generator) : generator.pick(from: pool)
      return Array(repeating: piece, count: generator.int(in: 8...40)).flatMap { $0 }
    }
  }

  private func mutated(_ units: [UInt16], using generator: inout SeededGenerator) -> [UInt16] {
    guard !units.isEmpty else { return generator.pick(from: pool) }
    var result = units
    let at = generator.int(in: 0...(units.count - 1))
    switch generator.int(in: 0...2) {
    case 0: result.remove(at: at)
    case 1: result.replaceSubrange(at...at, with: generator.pick(from: pool))
    default: result.insert(contentsOf: generator.pick(from: pool), at: at)
    }
    return result
  }

  private func cased(_ units: [UInt16], using generator: inout SeededGenerator) -> [UInt16] {
    let text = JSText.string(fromCodeUnits: units)
    switch generator.int(in: 0...3) {
    case 0: return text.uppercased().jsCodeUnits
    case 1: return text.capitalized.jsCodeUnits
    case 2: return text.unicodeScalars.flatMap { scalar in characterUnits(variant(of: scalar.value, using: &generator)) }
    default: return units
    }
  }

  private func variant(of value: UInt32, using generator: inout SeededGenerator) -> UInt32 {
    if let lookalike = Self.lookalikes[value], generator.chance(0.08) { return generator.pick(from: lookalike) }
    guard mode.ignoreCase, generator.chance(0.5) else { return value }
    return generator.pick(from: JSCaseFolding.equivalents(value, unicode: mode.unicode))
  }

  private func characterUnits(_ value: UInt32) -> [UInt16] {
    guard value > 0xFFFF, let scalar = Unicode.Scalar(value) else { return [UInt16(truncatingIfNeeded: value)] }
    return Array(String(scalar).utf16)
  }

  private static func shape(of node: JSRegexNode, mode: JSRegexMode) -> Shape {
    switch node {
    case .character(let value): .character(value)
    case .any: .any
    case .set(let set): .set(set, JSRegexCompiledSet(set, mode: mode))
    case .sequence(let terms): .sequence(terms.map { shape(of: $0, mode: mode) })
    case .alternation(let alternatives): .alternation(alternatives.map { shape(of: $0, mode: mode) })
    case .capture(let body, _): shape(of: body, mode: mode)
    case .lookaround, .anchor: .empty
    case .repetition(let body, let min, let max, _, _): .repetition(shape(of: body, mode: mode), min: min, max: max)
    }
  }

  private func sample(_ node: Shape, using generator: inout SeededGenerator) -> [UInt16] {
    switch node {
    case .character(let value):
      return characterUnits(variant(of: value, using: &generator))
    case .any:
      return generator.pick(from: pool)
    case .set(let set, let compiled):
      return member(of: set, compiled, using: &generator)
    case .sequence(let terms):
      return terms.flatMap { sample($0, using: &generator) }
    case .alternation(let alternatives):
      return sample(generator.pick(from: alternatives), using: &generator)
    case .empty:
      return []
    case .repetition(let body, let min, let max):
      let upper = Swift.min(max, min + (generator.chance(0.1) ? 12 : 3))
      return (0..<generator.int(in: min...upper)).flatMap { _ in sample(body, using: &generator) }
    }
  }

  private func member(of set: JSRegexCharacterSet, _ compiled: JSRegexCompiledSet, using generator: inout SeededGenerator) -> [UInt16] {
    for _ in 0..<40 {
      let candidate = candidate(for: set, using: &generator)
      guard let first = candidate.first else { continue }
      let value = candidate.count == 2 && mode.unicode ? (String(decoding: candidate, as: UTF16.self).unicodeScalars.first?.value ?? 0) : UInt32(first)
      if compiled.contains(value) { return mode.unicode ? candidate : [first] }
    }
    return generator.pick(from: pool)
  }

  private func candidate(for set: JSRegexCharacterSet, using generator: inout SeededGenerator) -> [UInt16] {
    guard !set.negated, !set.items.isEmpty, generator.chance(0.7) else { return generator.pick(from: pool) }
    switch generator.pick(from: set.items) {
    case .range(let lower, let upper):
      let value = UInt32(generator.int(in: Int(lower)...Int(Swift.min(upper, lower + 200))))
      return characterUnits(value)
    case .digit(false): return generator.pick(from: ["0", "1", "7", "9"]).jsCodeUnits
    case .space(false): return generator.pick(from: TextSamples.whitespace).jsCodeUnits
    case .word(false): return generator.pick(from: ["a", "Z", "_", "5", "s"]).jsCodeUnits
    case .property: return generator.pick(from: ["é", "中", "あ", "カ", "ไ", "A", "Ö", "z", "٣", "Ⅻ", "𝒜", "ǅ"]).jsCodeUnits
    default: return generator.pick(from: pool)
    }
  }
}
