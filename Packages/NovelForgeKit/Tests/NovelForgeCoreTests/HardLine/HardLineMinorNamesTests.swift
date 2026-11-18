import Foundation
import ShadowCore
import Testing

@testable import NovelForgeCore
@testable import ShadowAI

@Suite("Hard line minor names")
struct HardLineMinorNamesTests {
  private static let novel = UUID()

  private static func character(_ name: String, age: Int?, type: EntityType = .character) -> EntityRecord {
    EntityRecord(novel: novel, entity: name.lowercased(), type: .known(type), name: name, age: age)
  }

  private static func lexicon(_ records: EntityRecord...) -> HardLineLexicon {
    .standard(withMinorsIn: records)
  }

  private static func hit(_ text: String, _ lexicon: HardLineLexicon, scope: HardLineScope = .supplied) -> HardLineRule? {
    findHardLine([text], scope: scope, lexicon: lexicon)
  }

  @Test
  func shouldTreatTheNameOfACharacterUnderEighteenAsAMinorTerm() {
    let lexicon = Self.lexicon(Self.character("Tamsin", age: 12))
    #expect(Self.hit("Tamsin and the sex", lexicon) == .minorWithSexualContent)
    #expect(Self.hit("Tamsin and the orgasm", lexicon, scope: .background) == .minorWithExplicitAct)
    #expect(Self.hit("Tamsin and the sex", .standard) == nil)
  }

  @Test
  func shouldDrawTheLineBetweenSeventeenAndEighteen() {
    #expect(Self.hit("Rowan, sexy", Self.lexicon(Self.character("Rowan", age: 17))) == .minorWithSexualContent)
    #expect(Self.hit("Rowan, sexy", Self.lexicon(Self.character("Rowan", age: 18))) == nil)
    #expect(Self.hit("Rowan, sexy", Self.lexicon(Self.character("Rowan", age: 0))) == .minorWithSexualContent)
  }

  @Test
  func shouldAddNothingForAnUnknownOrUnusableAge() {
    #expect(Self.hit("Rowan, sexy", Self.lexicon(Self.character("Rowan", age: nil))) == nil)
    #expect(Self.hit("Rowan, sexy", Self.lexicon(Self.character("Rowan", age: -4))) == nil)
    #expect(Self.hit("Rowan, sexy", Self.lexicon(Self.character("Rowan", age: 4000))) == nil)
  }

  @Test
  func shouldAddNothingForAnEntityThatIsNotACharacter() {
    #expect(Self.hit("Harbor, sexy", Self.lexicon(Self.character("Harbor", age: 9, type: .location))) == nil)
    #expect(minorNames(in: [EntityRecord(novel: Self.novel, entity: "x", type: .unknown("spirit"), name: "Wisp", age: 9)]).isEmpty)
  }

  @Test
  func shouldIgnoreARemovedCharacter() {
    let entry = RecordEntry(record: Self.character("Tamsin", age: 12), isRemoved: true)
    let listing = RecordListing(entries: [entry], unreadable: 1)
    #expect(Self.hit("Tamsin, sexy", .standard(withMinorsIn: listing.live)) == nil)
  }

  @Test
  func shouldMatchWholeNamesWithoutCaseOrSpacingSensitivity() {
    let lexicon = Self.lexicon(Self.character("Mary Ann", age: 10))
    #expect(Self.hit("MARY   ANN, sex", lexicon) == .minorWithSexualContent)
    #expect(Self.hit("Maryann, sex", lexicon) == nil)
    #expect(Self.hit("Mary Annabel, sex", lexicon) == nil)
    #expect(Self.hit("Mary Ann. Sex", lexicon) == nil)
  }

  @Test
  func shouldEscapeRegularExpressionCharactersInAName() {
    let lexicon = Self.lexicon(Self.character("A.J. (Jay)", age: 9))
    #expect(Self.hit("A.J. (Jay), sex", lexicon) == .minorWithSexualContent)
    #expect(Self.hit("AxJx Jay, sex", lexicon) == nil)
    #expect(Self.hit("C++ (dev), sex", Self.lexicon(Self.character("C++ (dev)", age: 9))) == .minorWithSexualContent)
  }

  @Test
  func shouldScreenShortNamesWithSegmentBreaks() {
    #expect(minorNames(in: [Self.character("Jo.", age: 9)]) == ["Jo"])
    #expect(Self.hit("Bo, sex", Self.lexicon(Self.character("Bo.", age: 9))) == .minorWithSexualContent)
    #expect(Self.hit("Ed, sex", Self.lexicon(Self.character("Dr. Ed", age: 9))) == .minorWithSexualContent)
    #expect(Self.hit("Jo, sex", Self.lexicon(Self.character("St. Jo", age: 9))) == .minorWithSexualContent)
    #expect(Self.hit("Dr Patel, sex", Self.lexicon(Self.character("Dr. Ed", age: 9))) == nil)
    #expect(Self.hit("Dr, sex", Self.lexicon(Self.character("Dr.", age: 9))) == .minorWithSexualContent)
    #expect(Self.hit("Lady, sex", Self.lexicon(Self.character("Lady", age: 9))) == .minorWithSexualContent)
    #expect(minorNames(in: [Self.character("Dr. Sir", age: 9)]) == ["Dr", "Sir"])
    #expect(minorNames(in: [Self.character("A. Bo", age: 9)]) == ["Bo"])
    #expect(minorNames(in: [Self.character("...", age: 9)]).isEmpty)
  }

  @Test
  func shouldMatchANameWithoutItsTrailingParenthetical() {
    let lexicon = Self.lexicon(Self.character("Ann (Jr.)", age: 9))
    #expect(Self.hit("Ann, sex", lexicon) == .minorWithSexualContent)
    #expect(Self.hit("Annette, sex", lexicon) == nil)
  }

  @Test
  func shouldTreatApostropheVariantsAsEqual() {
    let lexicon = Self.lexicon(Self.character("O'Neil", age: 9))
    #expect(Self.hit("O\u{2019}Neil, sex", lexicon) == .minorWithSexualContent)
    #expect(Self.hit("O'Neil, sex", Self.lexicon(Self.character("O\u{2019}Neil", age: 9))) == .minorWithSexualContent)
  }

  @Test
  func shouldScreenTheFragmentsOfANameThatContainsASegmentBreak() {
    let lexicon = Self.lexicon(Self.character("St. Mortimer", age: 9))
    #expect(minorNames(in: [Self.character("St. Mortimer", age: 9)]) == ["Mortimer"])
    #expect(Self.hit("Mortimer, sex", lexicon) == .minorWithSexualContent)
    #expect(Self.hit("S, sex", lexicon) == nil)
    #expect(minorNames(in: [Self.character("A. Mortimer", age: 9)]) == ["Mortimer"])
  }

  @Test
  func shouldMatchANameAcrossUnicodeNormalisationForms() {
    let composed = "Zo\u{00EB}"
    let decomposed = "Zoe\u{0308}"
    for (stored, written) in [(composed, decomposed), (decomposed, composed)] {
      #expect(Self.hit("\(written), sex", Self.lexicon(Self.character(stored, age: 8))) == .minorWithSexualContent)
    }
  }

  @Test
  func shouldBoundANameAtNonAsciiLetters() {
    let lexicon = Self.lexicon(Self.character("\u{00C9}mile", age: 11))
    #expect(Self.hit("\u{00E9}mile, sex", lexicon) == .minorWithSexualContent)
    #expect(Self.hit("l\u{00E9}mile, sex", lexicon) == nil)
    #expect(Self.hit("Emile, sex", lexicon) == nil)
  }

  @Test
  func shouldKeepTheReferenceBehaviourForEverythingElse() {
    let lexicon = Self.lexicon(Self.character("Tamsin", age: 12))
    #expect(Self.hit("Tamsin walked home", lexicon) == nil)
    #expect(Self.hit("loli", lexicon) == .standaloneTerm)
    #expect(Self.hit("an adult, sex", lexicon) == nil)
    #expect(Self.hit("Tamsin. Sex", lexicon) == nil)
  }

  @Test
  func shouldSkipABlankNameAndDeduplicateEqualNames() {
    let records = [Self.character("  ", age: 5), Self.character("Tamsin", age: 5), Self.character("Tamsin", age: 6)]
    #expect(minorNames(in: records) == ["Tamsin"])
  }

  @Test
  func shouldRefuseARequestNamingAMinorOnAnUnrestrictedRoute() throws {
    let route = ModelRoute(
      task: .chat, pace: .steady, thinksDeeper: false, deepened: false, contentMode: .unrestricted, provider: .openRouter, model: "or/unrestricted", effort: nil,
      maxOutputTokens: 512, supportsNativeSchema: false)
    let lexicon = Self.lexicon(Self.character("Tamsin", age: 12))
    let requestGuard = try #require(RequestGuard.hardLine(for: route, lexicon: lexicon))
    #expect(throws: HardLineError.self) { try requestGuard.screen([WireMessage(content: .text("Tamsin, orgasm"))]) }
    try requestGuard.screen([WireMessage(content: .text("Tamsin, sexy"))])
  }
}
