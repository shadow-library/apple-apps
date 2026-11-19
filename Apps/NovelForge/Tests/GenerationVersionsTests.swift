import Foundation
import NovelForgeCore
import ShadowStore
import Testing

@testable import NovelForge

@MainActor
@Suite("Generation versions")
struct GenerationVersionsTests {
  private func entries(_ versions: GenerationVersions) throws -> [VersionEntry] {
    guard case .listed(let entries, _) = versions.versions.state else { throw ChatFixtureError.noBinding }
    return entries
  }

  private func twoRuns() async throws -> (world: GenerationWorld, hand: String) {
    let world = try await GenerationWorld.make([GenerationScripts.draft(), GenerationScripts.judge(), GenerationScripts.draft(GenerationScripts.other), GenerationScripts.judge()])
    let hand = try await world.handDraft("Hand-written.")
    await world.runtime.launch()
    let model = GenerationModel(novel: world.novel, chapter: 1)
    #expect(await model.start(.regenerate, options: GenerationOptions(), runtime: world.runtime) == .started)
    try await world.waitForRun(1)
    #expect(await model.start(.regenerate, options: GenerationOptions(), runtime: world.runtime) == .started)
    try await world.waitForRun(2)
    return (world, hand)
  }

  @Test func shouldGroupVersionsByRunMarkingTheHeadAndTheJudgedRevision() async throws {
    let (world, hand) = try await twoRuns()
    let versions = try await world.versions()

    let groups = VersionGrouping.group(try entries(versions), tags: versions.tags)

    #expect(groups.map(\.kind) == [.run(2), .run(1), .other])
    #expect(groups.map { $0.entries.count } == [1, 1, 1])
    #expect(groups[0].entries[0].version.isCurrent && !groups[1].entries[0].version.isCurrent)
    #expect(groups.dropLast().allSatisfy { $0.entries.allSatisfy { versions.judged.contains($0.version.revision) } })
    #expect(groups[2].entries.map(\.version.revision) == [hand] && !versions.judged.contains(hand))
  }

  @Test func shouldGroupSeveralSavesOfOneJobTogetherAndKeepUntaggedRunsOfVersionsApart() {
    let job = EntityKey(uuid: UUID())
    let tags = ["c": VersionTag(run: "r1", job: job), "b": VersionTag(run: "r1", job: job), "a": VersionTag(run: nil, job: nil)]

    let buckets = VersionGrouping.order(["c", "x", "b", "a", "y"], tags: tags)

    #expect(buckets.map(\.key) == [job.rawValue, nil])
    #expect(buckets.map(\.revisions) == [["c", "b"], ["x", "a", "y"]])
  }

  @Test func shouldOfferRestoreOnlyForANonCurrentVersionOfAChapterThatIsNotGenerating() async throws {
    let world = try await GenerationWorld.make(starter: GenerationStarters.refusing)
    let first = try await world.handDraft("First.")
    _ = try await world.handDraft("Second.")
    await world.runtime.launch()
    let before = try await world.versions()
    let all = try entries(before)
    let older = try #require(all.first { $0.version.revision == first })
    let current = try #require(all.first { $0.version.isCurrent })
    #expect(before.canRestore(older) && !before.canRestore(current))

    let engine = try #require(world.runtime.engine)
    _ = try await engine.request(NovelJobRequest(kind: .generate, novel: world.novel, chapter: 1, fingerprint: "open"))
    let during = try await world.versions()

    #expect(during.generating && !during.canRestore(older))
  }

  @Test func shouldCompareTwoVersionsAndRestoreTheOlderOne() async throws {
    let (world, hand) = try await twoRuns()
    let all = try entries(try await world.versions())
    let current = try #require(all.first { $0.version.isCurrent })
    let compare = VersionCompareModel(store: world.store, novel: world.novel, chapter: 1)

    await compare.load(older: hand, newer: current.version.revision)

    guard case .ready(let diff) = compare.state else { throw ChatFixtureError.noBinding }
    #expect(!diff.isIdentical && diff.wordsAdded > 0 && diff.wordsRemoved == 1)

    let model = ReaderModel(context: NovelContext(store: world.store, novel: world.novel))
    #expect(await model.restore(revision: hand, in: 1, current: current.version.revision))
    let restored = try await world.versions()
    let head = try #require(try entries(restored).first { $0.version.isCurrent })
    #expect(head.version.source?.known == .restored && head.version.restoredFrom == hand)
  }

  @Test func shouldRefuseARestoreWhileTheChapterIsGenerating() async throws {
    let world = try await GenerationWorld.make(starter: GenerationStarters.refusing)
    let old = try await world.handDraft("Hand-written.")
    await world.runtime.launch()
    let engine = try #require(world.runtime.engine)
    _ = try await engine.request(NovelJobRequest(kind: .generate, novel: world.novel, chapter: 1, fingerprint: "open"))
    let versions = try await world.versions()
    #expect(versions.generating)

    let model = ReaderModel(context: NovelContext(store: world.store, novel: world.novel))

    #expect(await !model.restore(revision: old, in: 1, current: old))
    #expect(
      model.failure?.error == PresentedError(headline: String(localized: "This chapter is being written. Wait for it to finish, or stop it.", table: "Reader"), detail: "DRF_019"))
  }

  @Test func shouldDiffWordsInsideAChangedParagraphAndFoldTheRest() {
    let older = "One.\n\nTwo.\n\nThree.\n\nFour is the old fourth.\n\nFive.\n\nSix."
    let newer = "One.\n\nTwo.\n\nThree.\n\nFour is the new fourth.\n\nFive.\n\nSix."

    let diff = VersionDiff.compare(from: older, to: newer)

    #expect(
      diff.rows == [
        .unchanged(2), .paragraph(DiffParagraph(pieces: [DiffPiece(op: .equal, text: "Three.")])),
        .paragraph(
          DiffParagraph(pieces: [
            DiffPiece(op: .equal, text: "Four is the"), DiffPiece(op: .delete, text: "old"), DiffPiece(op: .insert, text: "new"), DiffPiece(op: .equal, text: "fourth."),
          ])),
        .paragraph(DiffParagraph(pieces: [DiffPiece(op: .equal, text: "Five.")])), .unchanged(1),
      ])
    #expect(diff.wordsAdded == 1 && diff.wordsRemoved == 1 && !diff.isIdentical)
  }

  @Test func shouldKeepSoftLineBreaksInsideAParagraph() {
    let diff = VersionDiff.compare(from: "One two\nthree four.", to: "One two\nthree five.")

    guard case .paragraph(let paragraph) = diff.rows.first else {
      Issue.record("no paragraph")
      return
    }
    #expect(paragraph.pieces.map(\.text).joined().contains("two\nthree"))
    #expect(CompareVersionsSheet.attributed(paragraph).characters.contains("\n"))
  }

  @Test func shouldTreatTextThatDiffersOnlyInWhitespaceAsIdentical() {
    #expect(VersionDiff.compare(from: "A  b\nc.", to: "A b c.").isIdentical)
  }

  @Test func shouldShowAddedAndRemovedParagraphs() {
    let diff = VersionDiff.compare(from: "Keep.\n\nGone.", to: "Keep.\n\nNew one.\n\nNew two.")

    let changed = diff.rows.compactMap { row -> [DiffOp]? in
      guard case .paragraph(let paragraph) = row, paragraph.changed else { return nil }
      return paragraph.pieces.map(\.op)
    }
    #expect(changed.count == 2)
    #expect(diff.wordsAdded >= 3 && diff.wordsRemoved >= 1)
  }
}
