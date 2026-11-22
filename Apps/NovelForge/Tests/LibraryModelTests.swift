import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowStore
import SwiftUI
import Testing

@testable import NovelForge

@MainActor
@Suite("LibraryModel")
struct LibraryModelTests {
  private func makeModel() throws -> LibraryModel {
    LibraryModel(store: try NovelForgeStore.openInMemory())
  }

  private func observing(_ model: LibraryModel) -> Task<Void, Never> {
    Task { await model.observe() }
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<12_000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for the library to update")
  }

  @Test("should load an empty library")
  func loadsEmptyLibrary() async throws {
    let model = try makeModel()
    let task = observing(model)
    defer { task.cancel() }

    try await waitUntil { model.state.value != nil }

    #expect(model.state.value?.novels.isEmpty == true)
    #expect(model.state.value?.archived.isEmpty == true)
  }

  @Test("should list a created novel through observation and select it")
  func createAppearsInList() async throws {
    let model = try makeModel()
    let task = observing(model)
    defer { task.cancel() }
    try await waitUntil { model.state.value != nil }

    let id = try await model.create(title: "  The Ashfall Compact  ", notes: "Notes about ash.")

    try await waitUntil { model.state.value?.novels.map(\.novel.id) == [id] }
    #expect(model.state.value?.novels.first?.novel.displayTitle == "The Ashfall Compact")
    #expect(model.selection == id)
    #expect(try await model.loadNotes(novel: id) == "Notes about ash.")
  }

  @Test("should move a novel to the archived section and back")
  func archiveAndRestore() async throws {
    let model = try makeModel()
    let task = observing(model)
    defer { task.cancel() }
    let id = try await model.create(title: "Ashfall", notes: "")
    try await waitUntil { model.state.value?.novels.count == 1 }

    await model.archive(id)
    try await waitUntil { model.state.value?.archived.map(\.novel.id) == [id] }
    #expect(model.state.value?.novels.isEmpty == true)

    await model.restore(id)
    try await waitUntil { model.state.value?.novels.map(\.novel.id) == [id] }
    #expect(model.state.value?.archived.isEmpty == true)
    #expect(model.failure == nil)
  }

  @Test("should surface a failure instead of crashing when archiving a missing novel")
  func archiveMissingNovelSurfacesFailure() async throws {
    let model = try makeModel()

    await model.archive(UUID())

    #expect(model.failure != nil)
  }

  @Test("should list a clone under the typed name and keep the source title as the reference does")
  func cloneAppearsWithName() async throws {
    let model = try makeModel()
    let task = observing(model)
    defer { task.cancel() }
    let source = try await model.create(title: "Ashfall", notes: "")

    let copy = try await model.clone(source: source, name: "Ashfall (copy)")

    try await waitUntil { model.state.value?.novels.count == 2 }
    let clone = try #require(model.state.value?.novels.first { $0.novel.id == copy }?.novel)
    #expect(clone.name == "Ashfall (copy)")
    #expect(clone.displayTitle == "Ashfall")
    #expect(clone.hasDistinctName)
    #expect(model.selection == copy)
  }

  @Test("should ignore a request to present a sheet while another is open")
  func presentOverOpenSheetIsNoOp() throws {
    let model = try makeModel()
    model.present(.create)
    let clone = NovelRecord(id: UUID(), name: "Ashfall")

    model.present(.clone(clone))

    #expect(model.presenting == .create)
  }

  @Test("should clear a selection that is absent from a settled listing")
  func clearsMissingSelection() async throws {
    let model = try makeModel()
    let task = observing(model)
    defer { task.cancel() }
    try await waitUntil { model.state.value != nil }

    model.selection = UUID()
    model.reconcileSelection()

    #expect(model.selection == nil)
  }

  @Test("should keep a just-created selection until a listing has contained it")
  func keepsFreshSelection() async throws {
    let model = try makeModel()
    let task = observing(model)
    defer { task.cancel() }
    try await waitUntil { model.state.value != nil }
    let staleListing = model.state

    let id = try await model.create(title: "Ashfall", notes: "")
    model.reconcileSelection()
    #expect(model.selection == id)
    #expect(staleListing.value?.novels.isEmpty == true)

    try await waitUntil { model.state.value?.novels.map(\.novel.id) == [id] }
    model.reconcileSelection()
    #expect(model.selection == id)
  }

  @Test("should refuse a clone of a missing novel with an error and no new novel")
  func cloneMissingRefused() async throws {
    let model = try makeModel()

    await #expect(throws: DomainError.self) { _ = try await model.clone(source: UUID(), name: "Copy") }
  }
}

@MainActor
@Suite("NovelForm")
struct NovelFormTests {
  private func makeModel() throws -> LibraryModel {
    LibraryModel(store: try NovelForgeStore.openInMemory())
  }

  @Test("should create a novel with the untitled name when the title is blank")
  func blankTitleBecomesUntitled() async throws {
    let library = try makeModel()
    let form = NovelForm(mode: .create)

    let id = try #require(await form.submit(using: library))

    let record = try await library.store.read { transaction in try Library.novel(id, in: transaction) }
    #expect(record?.displayTitle == "Untitled novel")
  }

  @Test("should block submit and name the limit for an over-long title")
  func overLongTitleBlocked() throws {
    let form = NovelForm(mode: .create)
    form.title = String(repeating: "a", count: 256)

    #expect(!form.canSubmit)
    #expect(form.titleIssue == NovelFormIssues.titleTooLong(LibraryLimits.titleCharactersOnCreate))
  }

  @Test("should block submit when the notes pass the word limit")
  func overLongNotesBlocked() throws {
    let form = NovelForm(mode: .create)
    form.notes = Array(repeating: "word", count: 10_001).joined(separator: " ")

    #expect(!form.canSubmit)
    #expect(form.notesIssue == NovelFormIssues.notesOverWords)
  }

  @Test("should show a refusal from the domain inline and keep the form open")
  func refusedCloneShowsError() async throws {
    let library = try makeModel()
    let form = NovelForm(mode: .clone(source: UUID(), title: "Ashfall"))
    form.title = "Ashfall (copy)"

    let result = await form.submit(using: library)

    #expect(result == nil)
    #expect(form.issues.form?.detail == "PRJ_001")
    #expect(!form.isSubmitting)
  }

  @Test("should require a name to clone")
  func cloneRequiresName() {
    let form = NovelForm(mode: .clone(source: UUID(), title: "Ashfall"))

    #expect(!form.canSubmit)
    form.title = "   "
    #expect(!form.canSubmit)
    form.title = "Copy"
    #expect(form.canSubmit)
  }

  @Test("should save only the fields that changed when editing")
  func editSavesChangedFields() async throws {
    let library = try makeModel()
    let id = try await library.create(title: "Ashfall", notes: "First notes")
    let form = NovelForm(mode: .edit(novel: id, title: "Ashfall"))
    await form.loadNotes(using: library)
    #expect(form.notes == "First notes")
    #expect(!form.canSubmit)

    form.title = "Ashfall Compact"
    #expect(form.canSubmit)
    #expect(await form.submit(using: library) == id)

    let record = try await library.store.read { transaction in try Library.novel(id, in: transaction) }
    #expect(record?.title == "Ashfall Compact")
    #expect(try await library.loadNotes(novel: id) == "First notes")
  }

  @Test("should replace the notes when only the notes changed")
  func editNotesOnly() async throws {
    let library = try makeModel()
    let id = try await library.create(title: "Ashfall", notes: "First notes")
    let form = NovelForm(mode: .edit(novel: id, title: "Ashfall"))
    await form.loadNotes(using: library)

    form.notes = "Second notes"
    #expect(await form.submit(using: library) == id)

    #expect(try await library.loadNotes(novel: id) == "Second notes")
  }

  @Test("should clear the title when editing with a blank one so the name shows")
  func editBlankTitleClears() async throws {
    let library = try makeModel()
    let id = try await library.create(title: "Ashfall", notes: "")
    let copy = try await library.clone(source: id, name: "Ashfall draft")
    let form = NovelForm(mode: .edit(novel: copy, title: "Ashfall"))

    form.title = "  "
    #expect(form.canSubmit)
    #expect(await form.submit(using: library) == copy)

    let record = try #require(try await library.store.read { transaction in try Library.novel(copy, in: transaction) })
    #expect(record.title == nil)
    #expect(record.displayTitle == "Ashfall draft")
  }

  @Test("should count words and characters the way the core does")
  func countsLikeTheCore() {
    let form = NovelForm(mode: .create)

    form.notes = " one two  three\n"
    #expect(form.notesWords == 3)
    #expect(form.notesWordsLeft == LibraryLimits.notesWords - 3)
    #expect(form.notesWordsOver == 0)

    form.notes = Array(repeating: "w", count: LibraryLimits.notesWords + 5).joined(separator: " ")
    #expect(form.notesWordsOver == 5)
    #expect(form.notesWordsLeft == 0)
  }

  @Test("should measure the title limit on the trimmed text so trailing whitespace never blocks")
  func titleLimitAfterTrimming() {
    let form = NovelForm(mode: .create)
    form.title = String(repeating: " ", count: 10) + String(repeating: "a", count: LibraryLimits.titleCharactersOnCreate) + "   "
    #expect(form.canSubmit)
    #expect(form.titleIssue == nil)

    form.title += "a"

    #expect(!form.canSubmit)
    #expect(form.titleIssue == NovelFormIssues.titleTooLong(LibraryLimits.titleCharactersOnCreate))
  }

  @Test("should map domain refusals onto the field the author can fix")
  func mapsDomainErrors() {
    #expect(NovelFormIssues(.tooLong(field: "title", limit: 255)).title == NovelFormIssues.titleTooLong(255))
    #expect(NovelFormIssues(.blank(field: "name")).title != nil)
    #expect(NovelFormIssues(.notesTooLong(words: 10_001, maximum: 10_000)).notes == NovelFormIssues.notesOverWords)
    #expect(NovelFormIssues(.tooLong(field: "notes", limit: 100_000)).notes == NovelFormIssues.notesOverCharacters)
    #expect(NovelFormIssues(.novelNotFound(UUID())).form?.detail == "PRJ_001")
  }
}

@MainActor
@Suite("StatTile")
struct StatTileTests {
  @Test("should read an unavailable part as unavailable")
  func unavailablePart() {
    let reading = StatTile.Reading(Derived<Int>.unavailable([]), value: { Text(verbatim: "\($0)") })

    guard case .unavailable = reading else {
      Issue.record("expected an unavailable reading")
      return
    }
  }

  @Test("should read an available part as a value with its caption")
  func availablePart() {
    let reading = StatTile.Reading(Derived<Int>.available(3), value: { Text(verbatim: "\($0)") }, caption: { _ in Text(verbatim: "of 4") })

    guard case .value(let value, let caption) = reading else {
      Issue.record("expected a value reading")
      return
    }
    #expect(value == Text(verbatim: "3"))
    #expect(caption == Text(verbatim: "of 4"))
  }
}

@MainActor
@Suite("Novel overview observation")
struct OverviewObservationTests {
  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<12_000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for the overview")
  }

  @Test("should report a novel that does not exist as missing")
  func missingNovel() async throws {
    let store = try NovelForgeStore.openInMemory()
    let observer = ReadObserver<NovelOverview>()
    let task = Task { await observer.run { store.observe(NovelOverview.self, UUID()) } }
    defer { task.cancel() }

    try await waitUntil { observer.state.value != nil }

    #expect(observer.state.value?.presence == .missing)
  }

  @Test("should show a created novel and update when it is archived")
  func overviewFollowsArchive() async throws {
    let library = LibraryModel(store: try NovelForgeStore.openInMemory())
    let id = try await library.create(title: "Ashfall", notes: "")
    let store = library.store
    let observer = ReadObserver<NovelOverview>()
    let task = Task { await observer.run { store.observe(NovelOverview.self, id) } }
    defer { task.cancel() }
    try await waitUntil { observer.state.value != nil }
    guard case .present(let before) = try #require(observer.state.value).presence else { throw TestFailure.notPresent }
    #expect(!before.archived)

    await library.archive(id)

    try await waitUntil {
      guard case .present(let novel) = observer.state.value?.presence else { return false }
      return novel.archived
    }
    #expect(observer.state.value?.chapters.value?.known == 0)
  }
}

@MainActor
@Suite("NovelNavigator")
struct NovelNavigatorTests {
  private struct Route: Hashable {
    let id: Int
  }

  @Test("should start on the overview and switch sections")
  func showsSections() {
    let navigator = NovelNavigator()
    #expect(navigator.section == .overview)

    navigator.show(.notebook)

    #expect(navigator.section == .notebook)
  }

  @Test("should push a route onto its own section and keep other sections' paths")
  func opensRoutesPerSection() {
    let navigator = NovelNavigator()

    navigator.open(.reader, Route(id: 3))
    navigator.open(.story, Route(id: 9))

    #expect(navigator.section == .story)
    #expect(navigator.path(for: .reader).wrappedValue.count == 1)
    #expect(navigator.path(for: .story).wrappedValue.count == 1)
    #expect(navigator.path(for: .notebook).wrappedValue.isEmpty)
  }

  @Test("should replace the section's path when a route is opened and append when one is pushed")
  func openReplacesPushAppends() {
    let navigator = NovelNavigator()
    navigator.open(.reader, Route(id: 1))
    navigator.open(.reader, Route(id: 2))
    #expect(navigator.path(for: .reader).wrappedValue.count == 1)

    navigator.push(Route(id: 3))
    #expect(navigator.path(for: .reader).wrappedValue.count == 2)

    navigator.show(.story)
    navigator.push(Route(id: 4))
    #expect(navigator.path(for: .story).wrappedValue.count == 1)
    #expect(navigator.path(for: .reader).wrappedValue.count == 2)
  }

  @Test("should keep a section's path when another section is shown")
  func pathSurvivesSwitching() {
    let navigator = NovelNavigator()
    navigator.open(.reader, Route(id: 1))

    navigator.show(.overview)
    navigator.show(.reader)

    #expect(navigator.path(for: .reader).wrappedValue.count == 1)
  }

  @Test("should write a popped path back")
  func popsThroughBinding() {
    let navigator = NovelNavigator()
    navigator.open(.reader, Route(id: 1))

    navigator.path(for: .reader).wrappedValue.removeLast()

    #expect(navigator.path(for: .reader).wrappedValue.isEmpty)
  }

  @Test("should drop the navigators of novels that are gone")
  func prunes() {
    let navigators = NovelNavigators()
    let kept = UUID()
    let gone = UUID()
    navigators.navigator(for: kept).show(.reader)
    navigators.navigator(for: gone).show(.reader)

    navigators.prune(keeping: [kept])

    #expect(navigators.navigator(for: kept).section == .reader)
    #expect(navigators.navigator(for: gone).section == .overview)
  }

  @Test("should give each novel one navigator")
  func navigatorPerNovel() {
    let navigators = NovelNavigators()
    let first = UUID()
    let second = UUID()

    navigators.navigator(for: first).show(.reader)

    #expect(navigators.navigator(for: first) === navigators.navigator(for: first))
    #expect(navigators.navigator(for: first).section == .reader)
    #expect(navigators.navigator(for: second).section == .overview)
  }
}

@MainActor
@Suite("PresentedError")
struct PresentedErrorTests {
  @Test("should use the area's headline and keep the code as detail for a known domain error")
  func knownDomainError() {
    let error = PresentedError(DomainError.novelNotFound(UUID()), known: LibraryErrors.headline)

    #expect(error.headline == LibraryErrors.headline(for: .novelNotFound(UUID())))
    #expect(error.detail == "PRJ_001")
  }

  @Test("should never show developer text for an unknown domain error")
  func unknownDomainError() {
    let error = PresentedError(DomainError.chapterNotFound(4), known: LibraryErrors.headline)

    #expect(error.headline == PresentedError(DomainError.chapterNotFound(9)).headline)
    #expect(!error.headline.contains("Chapter not found"))
    #expect(error.detail == "CHP_001")
  }

  @Test("should show a storage message with the store code for a store error")
  func storeError() {
    let error = PresentedError(StoreError.database("disk I/O error at page 12"))

    #expect(error.detail == "store.database")
    #expect(!error.headline.contains("disk"))
  }

  @Test("should show a generic message with no detail for any other error")
  func otherError() {
    struct Boom: Error {}

    #expect(PresentedError(Boom()).detail == nil)
  }
}

private enum TestFailure: Error {
  case notPresent
}
