// apps/novel-forge-server/src/modules/ai/context/writer-context.ts:12
enum WriterRender {
  enum Cap {
    static let chapterPlan = 6_000
    static let prevEnding = 1_000
    static let continuationState = 2_000
    static let recentSummaries = 1_500
    static let povCard = 3_000
    static let castCard = 1_000
    static let knownFacts = 4_000
    static let chapterReveals = 1_500
    static let readerKnows = 1_500
    static let hiddenConstraints = 1_500
    static let allowedClues = 1_000
    static let openCanon = 3_000
    static let volumeGoal = 800
    static let completedVolumes = 1_500
    static let writingStyle = 4_100
    static let writerLines = 1_500
    static let pluginSection = 2_000
  }

  // writer-context.ts:36
  enum Priority {
    static let citedPage = 1
    static let castState = 2
    static let castCard = 3
    static let excessCard = 4
    static let readerKnows = 5
    static let pluginSection = 6
  }
}

// writer-context.ts:46
struct WriterReservation: Equatable, Sendable {
  var name: String
  var tokens: Int
  var cap: Int
  var fromPlan = false
}

/// What the renderers hand the assembler: the sections in the order they join the pack, the reservations the required ones make, and the facts cut for size.
struct WriterRendered: Equatable, Sendable {
  var sections: [ChatPackSection] = []
  var reservations: [WriterReservation] = []
  var omitted: [ChatPackOmission] = []

  // context-assembler.service.ts:243
  mutating func reserve(_ section: ChatPackSection, name: String, cap: Int, fromPlan: Bool = false) {
    var required = section
    required.required = true
    sections.append(required)
    reservations.append(WriterReservation(name: name, tokens: section.tokens, cap: cap, fromPlan: fromPlan))
  }

  // context-assembler.service.ts:247
  mutating func reserveDerived(_ section: ChatPackSection, name: String, cap: Int, fromPlan: Bool = false) {
    reserve(ChatPack.fitToCap(section, cap: cap), name: name, cap: cap, fromPlan: fromPlan)
  }

  mutating func append(_ other: WriterRendered) {
    sections += other.sections
    reservations += other.reservations
    omitted += other.omitted
  }
}
