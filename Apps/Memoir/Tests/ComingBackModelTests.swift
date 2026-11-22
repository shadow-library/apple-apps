import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("ComingBackModel", TestTimeLimit.standard)
struct ComingBackModelTests {
  private let scratch = ScratchDefaults()

  private var dismissal: ComingBackDismissal { ComingBackDismissal(defaults: scratch.defaults) }

  private func running(_ world: HeroWorld) async throws -> (ComingBackModel, Task<Void, Never>) {
    let model = ComingBackModel(context: world.context, dismissal: dismissal)
    let task = Task { await model.run() }
    try await until("coming back") { model.comingBack.state.value != nil }
    return (model, task)
  }

  /// An anchor left unkept on day 0, so day 1 offers its Recovery quest.
  private static func missedYesterday() async throws -> HeroWorld {
    let world = try await HeroWorld()
    _ = try await world.createQuests(["Stretch"], strictness: .anchor)
    try await world.walk(to: 1)
    return world
  }

  @Test("should say there is nothing to come back from before anything is missed")
  func readsNothingToComeBackFrom() async throws {
    let world = try await HeroWorld()
    _ = try await world.createQuests(["Stretch"], strictness: .anchor)
    let (model, task) = try await running(world)
    defer { task.cancel() }
    let value = try #require(model.comingBack.state.value)

    #expect(value.reason == nil && value.choices.isEmpty && value.recentlyMissed.isEmpty)
    #expect(model.effectiveIntensity == .standard && model.stagedIntensity == nil && !model.isDismissed)
    #expect(ComingBackCopy(reason: value.reason, claimed: value.comebackClaimed).headline == "Nothing to come back from")
  }

  @Test("should explain a Recovery day with the week's misses and choices that lead to today and the week")
  func explainsARecoveryDay() async throws {
    let world = try await Self.missedYesterday()
    let (model, task) = try await running(world)
    defer { task.cancel() }
    let value = try #require(model.comingBack.state.value)

    #expect(value.reason == .recovery && value.choices == [.keepRecoveryQuest, .reviewWeek])
    #expect(value.recentlyMissed.map(\.name) == ["Stretch"] && value.recentlyMissed.first?.misses.map(\.date) == [TestClock.day(0)])
    #expect(ComingBackCopy(reason: value.reason, claimed: false).headline == "A recovery quest is on today")
    let keep = ComingBackChoiceCopy(.keepRecoveryQuest, recovery: value.recovery)
    #expect(keep.destination == .today && keep.body.contains("Stretch"))
    #expect(ComingBackChoiceCopy(.reviewWeek, recovery: value.recovery).destination == .planningBoard)
    #expect(ComingBackCopy.missMeta(try #require(value.recentlyMissed.first)) == HeroDates.text(TestClock.day(0), year: false))
  }

  @Test("should stage an intensity through account.setIntensityMode and show it from tomorrow, the mode in force unchanged today")
  func stagesAnIntensity() async throws {
    let world = try await Self.missedYesterday()
    let (model, task) = try await running(world)
    defer { task.cancel() }

    await model.setIntensity(.lowIntensity)

    #expect(try await world.commands().last == .accountSetIntensityMode(IntensityModeChange(mode: .lowIntensity)))
    try await until("the staged mode") { model.stagedIntensity == .lowIntensity }
    #expect(model.comingBack.state.value?.intensityMode == .standard && model.effectiveIntensity == .lowIntensity && model.failure == nil)

    let count = try await world.commands().count
    await model.setIntensity(.lowIntensity)
    #expect(try await world.commands().count == count, "already staged, so nothing to write")

    try await world.walk(to: 2)
    try await until("the mode in force") { model.comingBack.state.value?.intensityMode == .lowIntensity }
    #expect(model.stagedIntensity == nil)
  }

  @Test("should go back to the mode in force by staging it, which then shows nothing staged")
  func restagesTheModeInForce() async throws {
    let world = try await Self.missedYesterday()
    let (model, task) = try await running(world)
    defer { task.cancel() }
    await model.setIntensity(.highIntensity)
    try await until("the staged mode") { model.stagedIntensity == .highIntensity }

    await model.setIntensity(.standard)

    #expect(try await world.commands().last == .accountSetIntensityMode(IntensityModeChange(mode: .standard)))
    try await until("nothing staged") { model.stagedIntensity == nil }
    #expect(model.effectiveIntensity == .standard)
  }

  @Test("should set the choices aside for the account's day only, on this device")
  func setsTheChoicesAsideForTheDay() async throws {
    let world = try await Self.missedYesterday()
    let (model, task) = try await running(world)
    defer { task.cancel() }

    model.dismiss()

    #expect(model.isDismissed)
    #expect(dismissal.isDismissed(on: TestClock.day(1)) && !dismissal.isDismissed(on: TestClock.day(2)))
    #expect(scratch.defaults.string(forKey: ComingBackDismissal.key) == TestClock.day(1).isoString)

    try await world.walk(to: 2)
    try await until("the next day") { model.comingBack.state.value?.openDay == TestClock.day(2) }
    #expect(!model.isDismissed)
  }

  @Test("should show an intensity write that fails, clear the pending mode and write nothing")
  func showsAFailedIntensityWrite() async throws {
    let world = try await Self.missedYesterday()
    let (model, task) = try await running(world)
    defer { task.cancel() }
    let before = try await world.commands()
    world.breakTheClock()

    await model.setIntensity(.lowIntensity)

    #expect(model.failure?.mode == .lowIntensity)
    #expect(model.failure?.error.headline == "The date on this device is outside the years Memoir can record. Check the device’s date and time.")
    #expect(model.pendingIntensity == nil)
    #expect(try await world.commands() == before)
  }

  @Test("should show nothing for an intensity write cancelled with its task")
  func showsNothingForACancelledIntensityWrite() async throws {
    let world = try await Self.missedYesterday()
    let (model, task) = try await running(world)
    defer { task.cancel() }
    let before = try await world.commands()

    let setting = Task { await model.setIntensity(.lowIntensity) }
    setting.cancel()
    await setting.value

    #expect(model.failure == nil && model.pendingIntensity == nil)
    #expect(try await world.commands() == before)
  }
}
