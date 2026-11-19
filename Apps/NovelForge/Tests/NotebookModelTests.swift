import Foundation
import NovelForgeCore
import ShadowStore
import SwiftUI
import Testing

@testable import NovelForge

@MainActor
@Suite("NotebookModel")
struct NotebookModelTests {
  private struct World {
    let model: NotebookModel
    let context: NovelContext
    let observing: Task<Void, Never>
  }

  private func makeWorld() async throws -> World {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await LibraryService(store: store).create(title: "Ashfall", notes: "")
    let context = NovelContext(store: store, novel: novel)
    let model = NotebookModel(context: context)
    let observing = Task { await model.observe() }
    let world = World(model: model, context: context, observing: observing)
    try await waitUntil { model.state.value != nil }
    return world
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<12_000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for the notebook to update")
  }

  private func watch(_ notes: NotebookNotes) async throws -> Task<Void, Never> {
    let task = Task { await notes.observe() }
    try await waitUntil { notes.isEditable }
    return task
  }

  private func store(_ text: String, in world: World) async throws {
    try await LibraryService(store: world.context.store).edit(novel: world.context.novel, title: nil, notes: text)
  }

  private func direction(_ statement: String, topic: String = "voice.tense") -> AuthorNotebookEntry {
    AuthorNotebookEntry(kind: .direction, topic: topic, statement: statement, why: "The reader should feel close.")
  }

  private func active(_ model: NotebookModel, _ topic: NotebookTopic = .directions) -> [String] {
    model.state.value?.entries(in: topic, showing: .active).map(\.record.statement) ?? []
  }

  @Test("should load an empty notebook")
  func loadsEmpty() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }

    for topic in NotebookTopic.allCases {
      #expect(world.model.state.value?.activeCount(in: topic) == 0)
      #expect(world.model.state.value?.earlierCount(in: topic) == 0)
    }
  }

  @Test("should show an added author entry under its topic")
  func addAppears() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }

    let id = try await world.model.add(direction("  Write in the past tense.  "))

    try await waitUntil { active(world.model) == ["Write in the past tense."] }
    guard case .found(let entry) = world.model.state.value?.lookup(id) else {
      Issue.record("the new entry should be found")
      return
    }
    #expect(entry.status == .active)
    #expect(entry.record.why == "The reader should feel close.")
    #expect(world.model.state.value?.activeCount(in: .directions) == 1)
    #expect(world.model.state.value?.activeCount(in: .backlog) == 0)
  }

  @Test("should file turned-down ideas and backlog entries under their own topics")
  func kindsRouteToTopics() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }

    _ = try await world.model.add(AuthorNotebookEntry(kind: .rejected, topic: "plot.twin", statement: "No evil twin."))
    _ = try await world.model.add(AuthorNotebookEntry(kind: .backlog, topic: "plot.sequel", statement: "A sequel, later."))

    try await waitUntil { active(world.model, .turnedDown) == ["No evil twin."] && active(world.model, .backlog) == ["A sequel, later."] }
    #expect(active(world.model, .directions).isEmpty)
  }

  @Test("should retire a rewritten entry from the active set and link it to its successor")
  func supersedeLinksSuccessor() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let old = try await world.model.add(direction("Write in the past tense."))
    try await waitUntil { active(world.model).count == 1 }

    let new = try await world.model.rewrite(old, as: NotebookRewrite(statement: "Write in the present tense."))

    try await waitUntil { active(world.model) == ["Write in the present tense."] }
    let snapshot = try #require(world.model.state.value)
    guard case .found(let retired) = snapshot.lookup(old), case .found(let current) = snapshot.lookup(new) else {
      Issue.record("both entries should be found")
      return
    }
    #expect(retired.status == .superseded)
    #expect(retired.state.successor == new)
    #expect(snapshot.successor(of: retired)?.id == new)
    #expect(snapshot.predecessor(of: current)?.id == old)
    #expect(snapshot.entries(in: .directions, showing: .all).count == 2)
    #expect(snapshot.earlierCount(in: .directions) == 1)
    #expect(Set(snapshot.history(of: current).map(\.id)) == Set([old, new]))
  }

  @Test("should withdraw an entry with its reason")
  func withdrawRemovesAndKeepsReason() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let id = try await world.model.add(direction("Write in the past tense."))
    try await waitUntil { active(world.model).count == 1 }

    try await world.model.withdraw(id, reason: "  Changed my mind.  ")

    try await waitUntil { active(world.model).isEmpty }
    let snapshot = try #require(world.model.state.value)
    guard case .found(let withdrawn) = snapshot.lookup(id) else {
      Issue.record("the withdrawn entry should still be found")
      return
    }
    #expect(withdrawn.status == .withdrawn)
    #expect(snapshot.reason(for: withdrawn) == "Changed my mind.")
    #expect(snapshot.entries(in: .directions, showing: .all).map(\.id) == [id])
  }

  @Test("should show a localized headline for a refused write")
  func refusedWriteIsLocalized() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }

    do {
      _ = try await world.model.add(direction("Reserved.", topic: "start.brief"))
      Issue.record("a reserved topic should be refused")
    } catch {
      let presented = NotebookErrors.present(error)
      #expect(presented.headline == String(localized: "That topic is reserved for Novel Forge. Choose another.", table: "Notebook"))
      #expect(presented.detail == "LDG_005")
    }
  }

  @Test("should surface a refused withdrawal on the form instead of closing it")
  func refusedWithdrawalStaysOnForm() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let id = try await world.model.add(direction("Write in the past tense."))
    try await waitUntil { active(world.model).count == 1 }
    try await world.model.withdraw(id, reason: "First.")
    try await waitUntil { active(world.model).isEmpty }
    guard case .found(let entry) = world.model.state.value?.lookup(id) else {
      Issue.record("the entry should be found")
      return
    }
    let form = NotebookWithdrawForm(entry: entry)
    form.reason = "Again."

    let submitted = await form.submit(using: world.model)

    #expect(!submitted)
    #expect(form.issues.form?.headline == String(localized: "This entry has already been replaced or withdrawn. Work on the current entry instead.", table: "Notebook"))
  }

  @Test("should map a blank statement onto the statement field")
  func blankStatementIssue() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }

    do {
      _ = try await world.model.add(direction("   "))
      Issue.record("a blank statement should be refused")
    } catch {
      #expect(NotebookFormIssues(error).statement == String(localized: "Write what this entry says.", table: "Notebook"))
    }
  }

  @Test("should not submit an add form with an invalid topic")
  func formRejectsInvalidTopic() async throws {
    let form = NotebookEntryForm(mode: .add(.direction))
    form.statement = "Something"
    form.topic = "Voice Tense"
    #expect(form.normalizedTopic == "voice-tense")
    #expect(form.canSubmit)

    form.topic = "start.brief"
    #expect(form.topicIssue != nil)
    #expect(!form.canSubmit)

    form.topic = "!!"
    #expect(form.topicIssue != nil)
    #expect(!form.canSubmit)
  }

  @Test("should resolve a route to a missing entry as not found")
  func missingEntryLookup() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }

    #expect(world.model.state.value?.lookup(UUID()) == .missing)
  }

  @Test("should treat server-owned topics as not found")
  func reservedTopicsAreHidden() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let novel = world.context.novel

    let id = try await world.context.store.write { transaction in
      try Notebook.record(NewNotebookEntry(kind: .system, topic: "progress.premise", statement: "Premise answered.", decidedBy: .system), novel: novel, in: &transaction).id
    }

    try await waitUntil { world.model.state.value?.ledger.entry(id) != nil }
    #expect(world.model.state.value?.lookup(id) == .missing)
    #expect(NotebookTopic.allCases.allSatisfy { world.model.state.value?.activeCount(in: $0) == 0 })
  }

  @Test("should rewrite a decision and keep it a decision")
  func rewriteDecision() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let novel = world.context.novel
    let id = try await world.context.store.write { transaction in
      try Notebook.record(NewNotebookEntry(kind: .decision, topic: "setting.era", statement: "Set in 1890.", decidedBy: .author), novel: novel, in: &transaction).id
    }
    try await waitUntil { active(world.model, .decisions) == ["Set in 1890."] }
    guard case .found(let entry) = world.model.state.value?.lookup(id) else {
      Issue.record("the decision should be found")
      return
    }
    let form = NotebookEntryForm(mode: .rewrite(entry))
    #expect(!form.canSubmit)
    form.statement = "Set in 1912."
    #expect(form.canSubmit)

    let new = await form.submit(using: world.model)

    #expect(new != nil)
    try await waitUntil { active(world.model, .decisions) == ["Set in 1912."] }
  }

  @Test("should save trimmed author's notes and reject over-long ones")
  func notesRoundTrip() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let notes = NotebookNotes(context: world.context)
    let watching = try await watch(notes)
    defer { watching.cancel() }
    #expect(notes.isEditable)
    #expect(!notes.canSave)

    notes.text = "  Ash falls on the capital.  "
    #expect(notes.canSave)
    await notes.save()

    #expect(notes.saveFailure == nil)
    #expect(notes.text == "Ash falls on the capital.")
    #expect(!notes.hasChanges)
    let reloaded = NotebookNotes(context: world.context)
    let reloading = try await watch(reloaded)
    defer { reloading.cancel() }
    #expect(reloaded.text == "Ash falls on the capital.")

    reloaded.text = Array(repeating: "word", count: LibraryLimits.notesWords + 1).joined(separator: " ")
    #expect(!reloaded.canSave)
    reloaded.revert()
    #expect(reloaded.text == "Ash falls on the capital.")
  }

  @Test("should show notes written elsewhere while the screen is open and nothing is being edited")
  func notesFollowTheStore() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let notes = NotebookNotes(context: world.context)
    let watching = try await watch(notes)
    defer { watching.cancel() }

    try await store("Ash falls on the capital.", in: world)

    try await waitUntil { notes.text == "Ash falls on the capital." }
    #expect(notes.stored == "Ash falls on the capital.")
    #expect(!notes.hasChanges)
    #expect(!notes.hasNewerVersion)
  }

  @Test("should keep an unsaved draft and flag a newer stored version")
  func draftSurvivesNewerStoredNotes() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let notes = NotebookNotes(context: world.context)
    let watching = try await watch(notes)
    defer { watching.cancel() }
    notes.text = "My draft."

    try await store("Written on another device.", in: world)

    try await waitUntil { notes.stored == "Written on another device." }
    #expect(notes.text == "My draft.")
    #expect(notes.hasChanges)
    #expect(notes.hasNewerVersion)

    notes.revert()

    #expect(notes.text == "Written on another device.")
    #expect(!notes.hasNewerVersion)
    #expect(!notes.hasChanges)
  }

  @Test("should not flag a newer version when the stored notes match the draft")
  func matchingStoredNotesAreNotNewer() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let notes = NotebookNotes(context: world.context)
    let watching = try await watch(notes)
    defer { watching.cancel() }
    notes.text = "Same words."

    try await store("Same words.", in: world)

    try await waitUntil { notes.stored == "Same words." }
    #expect(notes.text == "Same words.")
    #expect(!notes.hasNewerVersion)
    #expect(!notes.hasChanges)
  }

  @Test("should clear the newer-version flag when the draft is saved over it")
  func savingClearsNewerFlag() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let notes = NotebookNotes(context: world.context)
    let watching = try await watch(notes)
    defer { watching.cancel() }
    notes.text = "Mine."
    try await store("Theirs.", in: world)
    try await waitUntil { notes.hasNewerVersion }

    await notes.save()

    #expect(!notes.hasNewerVersion)
    #expect(notes.stored == "Mine.")
    try await waitUntil { notes.stored == "Mine." && !notes.hasChanges }
    #expect(notes.text == "Mine.")
  }

  @Test("should not hide a remote revision that landed between the write and the resume of a save")
  func saveDoesNotHideRemoteRevision() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let notes = NotebookNotes(context: world.context)
    let watching = try await watch(notes)
    defer { watching.cancel() }
    notes.text = "Mine."
    let previous = notes.stored
    try await store("Theirs.", in: world)
    try await waitUntil { notes.stored == "Theirs." }

    notes.finishSave("Mine.", submitted: "Mine.", previousStored: previous)

    #expect(notes.stored == "Theirs.")
    #expect(notes.text == "Mine.")
    #expect(notes.hasNewerVersion)
  }

  @Test("should register the unsaved notes for flushing only while they are dirty")
  func registersUnsavedNotes() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let work = UnsavedWork()
    let notes = NotebookNotes(context: world.context, unsavedWork: work)
    let watching = try await watch(notes)
    defer { watching.cancel() }
    #expect(!work.hasWork)

    notes.text = "Unsaved thoughts."
    #expect(work.hasWork)

    await work.flushAll()

    #expect(notes.stored == "Unsaved thoughts.")
    #expect(!work.hasWork)
    notes.text = "More."
    #expect(work.hasWork)
    notes.revert()
    #expect(!work.hasWork)
  }

  @Test("should unregister the notes flush when the notes are released")
  func unregistersOnRelease() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let work = UnsavedWork()
    var notes: NotebookNotes? = NotebookNotes(context: world.context, unsavedWork: work)
    let watching = try await watch(try #require(notes))
    notes?.text = "Unsaved."
    #expect(work.hasWork)

    watching.cancel()
    await watching.value
    notes = nil

    #expect(!work.hasWork)
  }

  @Test("should offer Decision on a rewrite only for decisions and system entries")
  func rewriteKindsDependOnOriginal() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let novel = world.context.novel
    let direction = try await world.model.add(direction("Write in the past tense."))
    let system = try await world.context.store.write { transaction in
      try Notebook.record(NewNotebookEntry(kind: .system, topic: "setting.era", statement: "Set in 1890.", decidedBy: .system), novel: novel, in: &transaction).id
    }
    let decision = try await world.context.store.write { transaction in
      try Notebook.record(NewNotebookEntry(kind: .decision, topic: "setting.place", statement: "Set in Lyon.", decidedBy: .author), novel: novel, in: &transaction).id
    }
    try await waitUntil { [direction, system, decision].allSatisfy { world.model.state.value?.ledger.entry($0) != nil } }
    let snapshot = try #require(world.model.state.value)

    func kinds(_ id: UUID) throws -> [LedgerEntryKind] {
      guard case .found(let entry) = snapshot.lookup(id) else { throw NotebookTestError.missing }
      return NotebookEntryForm(mode: .rewrite(entry)).kinds
    }

    #expect(try kinds(direction) == [.direction, .rejected, .backlog])
    #expect(try kinds(decision) == [.decision, .direction, .rejected, .backlog])
    #expect(try kinds(system) == [.decision, .direction, .rejected, .backlog])
  }

  @Test("should show the refusal to rewrite a non-decision as a decision on the form")
  func rewriteToDecisionRefused() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let id = try await world.model.add(direction("Write in the past tense."))
    try await waitUntil { active(world.model).count == 1 }

    do {
      _ = try await world.model.rewrite(id, as: NotebookRewrite(kind: .decision, statement: "Now a decision."))
      Issue.record("a direction cannot become a decision")
    } catch {
      let issues = NotebookFormIssues(error)
      #expect(issues.form?.detail == "LDG_003")
      #expect(issues.form?.headline == String(localized: "Only a decision can be rewritten as a decision.", table: "Notebook"))
    }
  }

  @Test("should keep the active and earlier choice per topic")
  func visibilityPerTopic() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }

    world.model.setVisibility(.all, of: .backlog)

    #expect(world.model.visibility(of: .backlog) == .all)
    #expect(world.model.visibility(of: .directions) == .active)
  }

  @Test("should pluralise every count string")
  func countsArePlural() {
    #expect(String(localized: "\(1) earlier", table: "Notebook") == "1 earlier")
    #expect(String(localized: "\(1) of \(10_000) words", table: "Notebook") == "1 of 10,000 words")
    #expect(String(localized: "\(1) words, \(3) over the limit", table: "Notebook") == "1 word, 3 over the limit")
    #expect(String(localized: "\(2) words, \(3) over the limit", table: "Notebook") == "2 words, 3 over the limit")
    #expect(NotebookErrors.headline(for: .tooLong(field: "why", limit: 1)) == "That is too long. Keep it to 1 character.")
    #expect(NotebookErrors.headline(for: .tooMany(field: "x", limit: 20)) == "There are too many items. Keep it to 20 items.")
    #expect(String(localized: "\(1) entries cannot be read", table: "Notebook") == "1 entry cannot be read")
  }

  @Test("should keep an over-limit draft when the notes screen is left and reopened")
  func overLimitDraftSurvivesLeaving() async throws {
    let world = try await makeWorld()
    defer { world.observing.cancel() }
    let notes = world.model.notes
    let first = try await watch(notes)
    let draft = Array(repeating: "word", count: LibraryLimits.notesWords + 1).joined(separator: " ")
    notes.text = draft

    notes.flush()
    first.cancel()
    let second = try await watch(notes)
    defer { second.cancel() }

    #expect(world.model.notes === notes)
    #expect(notes.text == draft)
    #expect(notes.wordsOver == 1)
    #expect(notes.hasChanges)
  }

  @Test("should show a failed flush of the notes when the screen is reopened")
  func failedFlushIsVisibleOnReturn() async throws {
    let store = try NovelForgeStore.openInMemory()
    let model = NotebookModel(context: NovelContext(store: store, novel: UUID()))
    let first = try await watch(model.notes)
    model.notes.text = "Ash falls."

    model.notes.flush()
    try await waitUntil { model.notes.saveFailure != nil }
    first.cancel()
    let second = try await watch(model.notes)
    defer { second.cancel() }

    #expect(model.notes.saveFailure != nil)
    #expect(model.notes.text == "Ash falls.")
  }

  #if os(macOS)
    private struct PushedHarness: View {
      let model: NotebookModel
      @State private var path: [NotebookRoute] = [.topic(.directions), .entry(UUID())]

      var body: some View {
        NavigationStack(path: $path) { NotebookView(model: model) }
      }
    }

    @Test("should present a sheet from a pushed topic and entry screen")
    func sheetPresentsFromPushedRoutes() async throws {
      let world = try await makeWorld()
      defer { world.observing.cancel() }
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: PushedHarness(model: world.model))
      window.orderFront(nil)
      defer { window.close() }
      try await Task.sleep(for: .milliseconds(300))

      world.model.present(.add(.direction))

      for _ in 0..<12_000 where window.sheets.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
      #expect(window.sheets.count == 1)
    }
  #endif
}

private enum NotebookTestError: Error {
  case missing
}
