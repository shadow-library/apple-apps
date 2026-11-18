import Foundation

@testable import NovelForgeCore

struct WriterRenderFixture: Decodable {
  struct FactSpec: Decodable {
    var factKey: String
    var text: String
    var constraintNote: String?
    var writerNote: String?
    var terms: [String]?
    var allowedClues: [String]?
    var subjects: [String]?

    var fact: DisclosureFact {
      DisclosureFact(factKey: factKey, text: text, constraintNote: constraintNote, writerNote: writerNote, terms: terms, allowedClues: allowedClues, subjects: subjects)
    }
  }

  struct PolicySpec: Decodable {
    var chapter: Int
    var lockedFacts: [FactSpec]
    var plannerOnly: [String]
    var plannerPages: [String]

    func policy() throws -> WriterDisclosurePolicy {
      try WriterDisclosurePolicy(
        WriterDisclosureInput(
          chapter: chapter, lockedFacts: lockedFacts.map(\.fact), plannerOnly: plannerOnly, plannerPages: plannerPages, volumeOrdinals: [:], currentVolumeOrdinal: nil))
    }
  }

  struct Withheld: Decodable, Equatable {
    var field: String
    var count: Int

    init(from decoder: any Decoder) throws {
      var container = try decoder.unkeyedContainer()
      field = try container.decode(String.self)
      count = try container.decode(Int.self)
    }

    init(_ counts: WithheldCount) {
      field = counts.field.rawValue
      count = counts.count
    }
  }

  struct Reservation: Decodable, Equatable {
    var name: String
    var tokens: Int
    var cap: Int
    var fromPlan: Bool

    init(_ reservation: WriterReservation) {
      name = reservation.name
      tokens = reservation.tokens
      cap = reservation.cap
      fromPlan = reservation.fromPlan
    }
  }

  struct Omission: Decodable, Equatable {
    var key: String
    var tokens: Int?

    init(_ omission: ChatPackOmission) {
      key = omission.key
      tokens = omission.tokens
    }
  }

  struct Rendered: Decodable {
    var sections: [ChatPackSection]
    var reservations: [Reservation]
    var omitted: [Omission]
    var withheld: [Withheld]
  }

  struct Volume: Decodable {
    struct Chapter: Decodable {
      var number: Int
      var summary: String
    }

    var ordinal: Int
    var title: String
    var goal: String?
    var chapters: [Chapter]

    var volume: WriterCompletedVolume {
      WriterCompletedVolume(ordinal: ordinal, title: title, goal: goal, chapters: chapters.map { WriterVolumeChapter(number: $0.number, summary: $0.summary) })
    }
  }

  struct VolumesCase: Decodable {
    var id: String
    var volumes: [Volume]
    var maxTokens: Int
    var policy: PolicySpec?
    var expected: String?
    var withheld: [Withheld]
  }

  struct EndingRow: Decodable {
    var status: String
    var isolated: Bool
    var content: String?
    var summary: String?
  }

  struct EndingDraft: Decodable {
    var body: String?
    var summary: String?
    var stateJson: String?
    var isolated: Bool
    var staleReason: String?
  }

  struct EndingExpected: Decodable {
    var ending: ChatPackSection?
    var state: ChatPackSection?
    var sections: [ChatPackSection]
    var reservations: [Reservation]
    var withheld: [Withheld]
  }

  struct EndingCase: Decodable {
    struct Caps: Decodable {
      var ending: Int
      var state: Int
    }

    var id: String
    var chapter: Int
    var row: EndingRow?
    var draft: EndingDraft?
    var rawIsolated: Bool
    var policy: PolicySpec
    var caps: Caps?
    var expected: EndingExpected
  }

  struct Pov: Decodable {
    var entityKey: String
    var name: String
  }

  struct ViewSpec: Decodable {
    var known: [FactSpec]
    var reveals: [FactSpec]
    var hidden: [FactSpec]
    var readerKnows: [FactSpec]
    var pooledPov: [Pov]
    var learnedIn: [LearnedSpec]?

    var view: KnowledgeView {
      KnowledgeView(
        known: known.map(\.fact), reveals: reveals.map(\.fact), hidden: hidden.map(\.fact), readerKnows: readerKnows.map(\.fact),
        pooledPov: pooledPov.map { PovMember(entityKey: $0.entityKey, name: $0.name) },
        learnedIn: learnedIn.map { $0.map { LearnedChapter(factKey: $0.factKey, chapter: $0.chapter) } })
    }
  }

  struct LearnedSpec: Decodable {
    var factKey: String
    var chapter: Int

    init(from decoder: any Decoder) throws {
      var container = try decoder.unkeyedContainer()
      factKey = try container.decode(String.self)
      chapter = try container.decode(Int.self)
    }
  }

  struct KnowledgeCase: Decodable {
    var id: String
    var view: ViewSpec
    var chapterCast: [String]
    var policy: PolicySpec
    var contract: Bool
    var expected: Rendered
  }

  struct LedgerSpec: Decodable {
    var kind: String
    var topic: String
    var statement: String
    var why: String?
    var rejectedAlternatives: [String]
    var writerLine: String?
    var decidedBy: String

    var entry: ChatPackLedgerEntry {
      ChatPackLedgerEntry(
        kind: LedgerEntryKind(rawValue: kind) ?? .decision, topic: topic, statement: statement, why: why, rejectedAlternatives: rejectedAlternatives, writerLine: writerLine,
        decidedBy: LedgerDecidedBy(rawValue: decidedBy) ?? .author, ideaId: nil, rejectionScope: nil)
    }
  }

  struct LinesCase: Decodable {
    var id: String
    var entries: [LedgerSpec]
    var policy: PolicySpec
    var expected: Rendered
  }

  struct Loose: Decodable {
    var value: String?

    init(from decoder: any Decoder) throws {
      value = try? decoder.singleValueContainer().decode(String.self)
    }
  }

  struct LooseList: Decodable {
    var items: [String]

    init(from decoder: any Decoder) throws {
      items = ((try? decoder.singleValueContainer().decode([Loose].self)) ?? []).compactMap(\.value)
    }
  }

  struct Ending: Decodable {
    var hookType: String
    var emotionalBeat: String
    var openQuestion: String
    var handoffState: String
    var mustNotResolve: [String]?

    var contract: ChapterEndingContract {
      ChapterEndingContract(
        hookType: StoredEnum<HookType>(rawValue: hookType), emotionalBeat: emotionalBeat, openQuestion: openQuestion, handoffState: handoffState, mustNotResolve: mustNotResolve)
    }
  }

  struct BriefSpec: Decodable {
    var body: String?
    var pov: String?
    var chapterPurpose: String?
    var readerValue: LooseList?
    var repetitionRisks: LooseList?
    var guidance: String?
    var endingContract: Ending?

    var input: WriterBriefInput {
      WriterBriefInput(
        body: body, pov: pov, chapterPurpose: chapterPurpose, readerValue: readerValue?.items ?? [], repetitionRisks: repetitionRisks?.items ?? [], guidance: guidance,
        endingContract: endingContract?.contract)
    }
  }

  struct BriefExpected: Decodable {
    var chapterBrief: String
    var endingContract: String
    var withheld: [Withheld]
  }

  struct BriefCase: Decodable {
    var id: String
    var brief: BriefSpec?
    var facts: [FactSpec]
    var policy: PolicySpec
    var expected: BriefExpected
  }

  struct StyleExpected: Decodable {
    var section: ChatPackSection
    var withheld: [Withheld]
  }

  struct StyleCase: Decodable {
    var id: String
    var stored: String?
    var policy: PolicySpec
    var expected: StyleExpected
  }

  var caps: [String: Int]
  var priorities: [String: Int]
  var completedVolumes: [VolumesCase]
  var previousEnding: [EndingCase]
  var knowledge: [KnowledgeCase]
  var writerLines: [LinesCase]
  var brief: [BriefCase]
  var writingStyle: [StyleCase]

  static let shared = Result { try ReferenceFixture.decode(WriterRenderFixture.self, from: "writer-pack-render/writer-pack-render.json") }
}
