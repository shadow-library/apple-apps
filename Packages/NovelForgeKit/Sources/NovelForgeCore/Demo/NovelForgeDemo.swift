import Foundation
import ShadowStore

/// The demo's sample novel, written into a fresh demo vault: a premise, a small Story Bible, the first volume of the outline with a milestone, and the brief
/// of chapter 1, so the author can chat about it, plan chapter 2 and write chapter 1 at once. `script` answers every call the demo makes about it.
public enum NovelForgeDemo {
  public static let novel = UUID(uuidString: "5e1c0de0-0000-4000-8000-00000000d301") ?? UUID()
  static let title = "The Salt Clock"
  static let wordTarget = WordTarget(min: 500, max: 1500)

  static let protagonist = "ines"
  static let harbourmaster = "teodor"
  static let tower = "harbour_tower"
  static let clock = "salt_clock"
  static let slowClock = "slow_clock"
  static let volume = "the_slow_hour"
  static let shimFound = "shim_found"

  /// Writes the sample novel once; a vault that already holds it is left as it is.
  public static func seed(in store: VaultStore) async throws(StoreError) {
    let novel = novel
    try await store.write { transaction in
      guard try NovelRecord.read(id: novel, in: transaction).entry == nil else { return }
      _ = try NovelRecord(
        id: novel, name: title, title: title, wordTarget: wordTarget,
        brief: "A harbour mystery in a small fishing town, told close on one apprentice clockmaker over a single autumn.",
        premise:
          "In the fishing town of Saltmere every boat sails by the tide bell of the harbour tower clock. Apprentice clockmaker Ines Varga finds the clock has been running eleven minutes slow for a year, logged in her own hand, and someone in town has been paying to keep it that way.",
        theme: "Trust in shared measures, and what it costs to keep them honest.", endingQuestion: "Who has been selling the town's lost minutes, and why?",
        protagonist: "Ines Varga, apprentice keeper of the harbour clock", opposition: "Whoever profits from the late tide, and the town's reluctance to doubt its clock",
        writingStyle: "Close third person, past tense; plain, concrete sentences with the sea always in earshot."
      ).create(in: &transaction)
      _ = try AuthorNotesRecord(
        novel: novel,
        content: AuthorNotesContent(
          text: "Keep the mystery fair: every clue Ines finds should be on the page. Teodor is not the villain, but he should look like he could be until chapter 3.")
      ).create(in: &transaction)
      for entity in entities(novel) { _ = try entity.create(in: &transaction) }
      _ = try ThreadRecord(novel: novel, thread: slowClock, summary: "Who slows the harbour clock, and who buys the eleven minutes", openedChapter: 1, payoffVolume: volume).create(
        in: &transaction)
      _ = try VolumeRecord(
        novel: novel, volume: volume, ordinal: 1, title: "The Slow Hour",
        objective: "Ines discovers the clock is being slowed on purpose and learns who in Saltmere is buying the late tide.",
        body:
          "Chapter 1: Ines finds the clock eleven minutes slow and a hand-filed shim. Chapter 2: Teodor shows her the harbour ledger. Chapter 3: the first boat comes in ahead of the bell."
      ).create(in: &transaction)
      _ = try MilestoneRecord(novel: novel, milestone: shimFound, label: "Ines finds the brass shim behind the pendulum spring", kind: .known(.event)).create(in: &transaction)
      _ = try ChapterPlanRecord(novel: novel, chapter: 1, content: firstBrief).create(in: &transaction)
    }
  }

  private static func entities(_ novel: UUID) -> [EntityRecord] {
    [
      EntityRecord(
        novel: novel, entity: protagonist, type: .known(.character), name: "Ines Varga", significance: .known(.major), status: "Apprentice keeper of the harbour clock",
        motivation: "To be trusted with the tower the way her master was", appearance: "Twenty-two, ink and oil on her cuffs, always carries Hale's pocket watch", age: 22),
      EntityRecord(
        novel: novel, entity: harbourmaster, type: .known(.character), name: "Teodor Brask", significance: .known(.major), status: "Harbourmaster of Saltmere",
        motivation: "To find out who is cheating the harbour before the council blames the clock", appearance: "A big man in a wet oilskin, harbour keys on a chain"),
      EntityRecord(
        novel: novel, entity: tower, type: .known(.location), name: "The harbour tower", significance: .known(.major),
        notes: "Ninety-one steps to the clock room; the tide bell's rope runs through a hole in the floor."),
      EntityRecord(
        novel: novel, entity: clock, type: .known(.item), name: "The salt clock", significance: .known(.major),
        notes: "The tower's movement. It rings the tide bell, and no boat in Saltmere sails before it."),
    ]
  }

  static let firstBrief = ChapterPlanContent(
    title: firstChapterTitle,
    body:
      "Before dawn Ines winds the harbour clock and finds it eleven minutes behind her watch and the church clock. The log shows a year of small corrections in her own hand that she does not remember. Behind the pendulum spring she finds a hand-filed brass shim. As she pockets it she hears someone climbing the stairs.",
    volume: volume, contextRefs: ["entity:\(protagonist)", "entity:\(tower)", "entity:\(clock)", "thread:\(slowClock)"], pov: protagonist,
    endingContract: ChapterEndingContract(
      hookType: .known(.cliffhanger), emotionalBeat: "Held breath in the dark", openQuestion: "Who is climbing the tower stairs so carefully?",
      handoffState: "Ines in the dark clock room with the shim in her hand, footsteps on the stairs below", mustNotResolve: ["thread:\(slowClock)"]),
    contract: ChapterContract(pov: [protagonist], claimedMilestones: [shimFound]),
    chapterPurpose: "Open the mystery of the slow clock and put the first clue in Ines's hand.", readerValue: ["new_information"],
    scenes: [
      PlanScene(
        BriefScene(
          summary: "Ines climbs the tower and winds the clock before dawn.", pov: protagonist, goal: "Wind the clock before the tide bell",
          obstacle: "Her watch and the tower dial disagree", turn: "The tower is eleven minutes slow", beats: ["The climb", "The winding", "The two clocks"],
          estimatedWords: 300)),
      PlanScene(
        BriefScene(
          summary: "Ines reads the log and finds the shim.", pov: protagonist, goal: "Find out why the clock is slow", obstacle: "The log entries are in her own hand",
          turn: "Someone is on the stairs", beats: ["The log", "The shim", "Footsteps"], estimatedWords: 350)),
    ])
}
