import Foundation
import GRDB
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Read model observation", TestTimeLimit.standard)
struct ReadModelObservationTests {
  @Test func shouldEmitTheCurrentValueThenAgainAfterARelevantWrite() async throws {
    let store = try await ReadWorld.seeded()
    let (collected, task) = collect(store.observe(ChapterList.self, readNovel))
    defer { task.cancel() }
    #expect(await collected.wait(for: 1))
    try await ReadWorld.write(store) { transaction in try ChapterWrites.approve(novel: readNovel, chapter: 3, in: &transaction) }
    #expect(await collected.wait(for: 2))
    let values = await collected.values
    #expect(values[0].rows.value?.map(\.stage) == [.final, .approved, .drafted, .planned])
    #expect(values[1].rows.value?.map(\.stage) == [.final, .approved, .approved, .planned])
  }

  @Test func shouldNotEmitAfterAWriteThatLeavesTheModelUnchanged() async throws {
    let store = try await ReadWorld.seeded()
    let (collected, task) = collect(store.observe(ChapterList.self, readNovel))
    defer { task.cancel() }
    #expect(await collected.wait(for: 1))
    try await ReadWorld.write(store) { transaction in try PlanWorldWrites.putPlan(novel: readOtherNovel, chapter: 1, planContent(), in: &transaction) }
    try await Task.sleep(for: .milliseconds(500))
    #expect(await collected.values.count == 1)
    try await ReadWorld.write(store) { transaction in try ChapterWrites.draft(novel: readNovel, chapter: 4, in: &transaction) }
    #expect(await collected.wait(for: 2))
  }

  @Test func shouldObserveAModelThatReadsRecordsAndStopWhenCancelled() async throws {
    let store = try await ReadWorld.seeded()
    let (collected, task) = collect(store.observe(StoryBibleContents.self, readNovel))
    #expect(await collected.wait(for: 1))
    try await ReadWorld.write(store) { transaction in _ = try Pages.save(novel: readNovel, section: .world, slug: "tides", body: "Salt.", in: &transaction) }
    #expect(await collected.wait(for: 2))
    task.cancel()
    try await ReadWorld.write(store) { transaction in _ = try Pages.save(novel: readNovel, section: .world, slug: "ash", body: "Ash.", in: &transaction) }
    try await Task.sleep(for: .milliseconds(300))
    #expect(await collected.values.count == 2)
  }

  @Test func shouldObserveTheLibraryWithoutInput() async throws {
    let store = try await ReadWorld.seeded()
    let (collected, task) = collect(store.observe(LibraryList.self))
    defer { task.cancel() }
    #expect(await collected.wait(for: 1))
    try await ReadWorld.write(store) { transaction in _ = try NovelRecord(id: UUID(), name: "Birch").create(in: &transaction) }
    #expect(await collected.wait(for: 2))
    #expect(await collected.values.last?.novels.count == 2)
  }
}
