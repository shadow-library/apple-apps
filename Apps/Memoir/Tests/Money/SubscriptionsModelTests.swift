import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("Subscriptions", TestTimeLimit.standard)
struct SubscriptionsModelTests {
  private static func music(_ context: MemoirScreenContext, due: LocalDate = TestClock.day0) async throws -> UUID {
    let form = SubscriptionForm(options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.english)
    form.name = " Music "
    form.amountText = "11.99"
    form.nextDue = due
    return try #require(await form.save())
  }

  @Test("should create a subscription with its command and the billing day of its due date")
  func createsASubscription() async throws {
    let context = try await MoneyFixture.context()
    let id = try await Self.music(context, due: TestClock.day(30))

    let record = try #require(try await MoneyFixture.subscriptions(context).first?.record)
    #expect(record.id == id)
    #expect(record.name == "Music")
    #expect(record.amountMinor == 1199)
    #expect(record.currency == MoneyFixture.euro)
    #expect(record.frequency == .known(.monthly))
    #expect(record.anchorOn == TestClock.day(30))
    #expect(record.billingDay == TestClock.day(30).day)
    #expect(record.category == MoneyFixture.subs)
    #expect(record.reminderEnabled && record.reminderLead == .known(.oneDay))
    #expect(try await MoneyFixture.bodies(context) == [.subscriptionCreate(RecordReference(id: id))])
  }

  @Test("should refuse a blank name and a due date before today")
  func refusesABlankName() async throws {
    let context = try await MoneyFixture.context()
    let form = SubscriptionForm(options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.english)
    form.name = "   "
    form.amountText = "5"
    #expect(form.nameIssue != nil)
    #expect(!form.canSave)
    form.name = "Gym"
    form.nextDue = TestClock.day(-1)
    #expect(!form.canSave)
    #expect(await form.save() == nil)
    #expect(try await MoneyFixture.subscriptions(context).isEmpty)
  }

  @Test("should confirm a due cycle once, writing its expense under the derived id, and move the next due date")
  func confirmsACycle() async throws {
    let context = try await MoneyFixture.context()
    let id = try await Self.music(context)
    let model = SubscriptionsModel(context: context)
    let running = Task { await model.run() }
    defer { running.cancel() }

    let overview = try #require(try await MoneyFixture.loaded(model.overview, "the subscription") { $0?.items.count == 1 })
    let standing = try #require(overview.items.first)
    #expect(standing.dueState == .due)

    await model.confirm(standing, locale: MoneyFixture.english)
    #expect(model.failure == nil)
    #expect(model.notice?.contains("Music") == true)
    let confirmation = CycleConfirmation(subscription: id, billingDate: TestClock.day0)
    let expenses = try await MoneyFixture.expenseEntries(context).map(\.record)
    #expect(expenses.map(\.id) == [SubscriptionCycles.expenseID(for: confirmation)])
    #expect(expenses.first?.amountMinor == 1199)
    #expect(try await MoneyFixture.bodies(context).last == .subscriptionConfirmCycle(confirmation))

    let moved = try await MoneyFixture.loaded(model.overview, "the next cycle") { $0?.items.first?.nextDue == LocalDate(isoString: "2026-04-02") }
    #expect(moved?.items.first?.dueState == SubscriptionDueState.none)

    await model.confirm(standing, locale: MoneyFixture.english)
    #expect(model.notice == String(localized: "Already confirmed for this cycle.", table: "Money"))
    #expect(try await MoneyFixture.expenseEntries(context).count == 1)
  }

  @Test("should pause and resume a subscription through its update command")
  func pausesAndResumes() async throws {
    let context = try await MoneyFixture.context()
    let id = try await Self.music(context)
    let model = SubscriptionsModel(context: context)

    await model.setActive(id, false)
    #expect(try await MoneyFixture.subscriptions(context).first?.record.active == false)
    #expect(model.notice == String(localized: "Subscription paused.", table: "Money"))
    await model.setActive(id, false)
    #expect(try await MoneyFixture.bodies(context).filter { $0 == .subscriptionUpdate(RecordReference(id: id)) }.count == 1, "no change, no command")
    await model.setActive(id, true)
    #expect(try await MoneyFixture.subscriptions(context).first?.record.active == true)
  }

  @Test("should open an edit on the next due date after a confirmed cycle and keep it after that cycle")
  func editsAfterAConfirmation() async throws {
    let context = try await MoneyFixture.context()
    let id = try await Self.music(context)
    let confirmation = CycleConfirmation(subscription: id, billingDate: TestClock.day0)
    _ = try await context.writer.write { issuer, transaction in try issuer.confirmCycle(confirmation, in: &transaction).expense }

    let form = try #require(try await SubscriptionForm.load(id, context: context, locale: MoneyFixture.english))
    let april = try #require(LocalDate(isoString: "2026-04-02"))
    #expect(form.nextDue == april, "the derived next due date, not the anchor")
    #expect(form.earliestDue == TestClock.day(1))
    #expect(!form.hasChanges)
    form.nextDue = TestClock.day0
    #expect(form.dueIssue != nil)
    #expect(!form.canSave)

    let may = try #require(LocalDate(isoString: "2026-05-02"))
    form.nextDue = may
    #expect(form.dueIssue == nil)
    #expect(await form.save() == id)
    let record = try #require(try await MoneyFixture.subscriptions(context).first?.record)
    #expect(record.anchorOn == may && record.billingDay == 2)
    let model = SubscriptionsModel(context: context)
    let running = Task { await model.run() }
    defer { running.cancel() }
    _ = try await MoneyFixture.loaded(model.overview, "the moved due date") { $0?.items.first?.nextDue == may }
  }

  @Test("should write only the fields the form moved, keeping a pause and a note made while it was open")
  func keepsConcurrentChanges() async throws {
    let context = try await MoneyFixture.context()
    let id = try await Self.music(context)
    let form = try #require(try await SubscriptionForm.load(id, context: context, locale: MoneyFixture.english))
    try await context.writer.write { issuer, transaction in
      try SubscriptionWrites.update(id, issuer: issuer, in: &transaction) { subscription in
        subscription.active = false
        subscription.note = "Family plan"
      }
    }

    form.amountText = "12.99"
    #expect(await form.save() == id)

    let record = try #require(try await MoneyFixture.subscriptions(context).first?.record)
    #expect(record.amountMinor == 1299)
    #expect(!record.active)
    #expect(record.note == "Family plan")
    #expect(record.name == "Music")
  }

  @Test("should edit and delete a subscription, and refuse one that is gone")
  func editsAndDeletes() async throws {
    let context = try await MoneyFixture.context()
    let id = try await Self.music(context)
    let record = try #require(try await MoneyFixture.subscriptions(context).first?.record)
    let form = SubscriptionForm(editing: record, options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.english)
    #expect(form.amountText == "11.99")
    #expect(!form.canSave)
    form.frequency = .custom
    form.customIntervalDays = 14
    #expect(await form.save() == id)
    let edited = try #require(try await MoneyFixture.subscriptions(context).first?.record)
    #expect(edited.frequency == .known(.custom) && edited.customIntervalDays == 14)

    try await context.writer.write { issuer, transaction in
      try SubscriptionWrites.update(id, issuer: issuer, in: &transaction) { $0.note = "Family plan" }
    }
    #expect(await form.delete())
    let removed = try #require(try await MoneyFixture.subscriptions(context).first)
    #expect(removed.isRemoved)
    #expect(removed.record.note == nil, "the owner's words go with it")
    #expect(try await MoneyFixture.bodies(context).last == .subscriptionDelete(RecordReference(id: id)))

    let model = SubscriptionsModel(context: context)
    await model.setActive(id, false)
    #expect(model.failure?.headline == String(localized: "That subscription no longer exists.", table: "Writing"))
  }
}

@MainActor
@Suite("CategoriesModel", TestTimeLimit.standard)
struct CategoriesModelTests {
  @Test("should archive a category with its command and record, hide it from new entries, and restore it")
  func archivesAndRestores() async throws {
    let context = try await MoneyFixture.context()
    let model = CategoriesModel(context: context)
    let running = Task { await model.run() }
    defer { running.cancel() }
    _ = try await MoneyFixture.loaded(model.overview, "the categories")

    await model.setArchived(MoneyFixture.transport, true)
    #expect(model.failure == nil)
    let archived = try await MoneyFixture.loaded(model.overview, "the archived category") { snapshot in
      snapshot.overview.categories.first { $0.key == MoneyFixture.transport }?.isArchived == true
    }
    #expect(archived.home == MoneyFixture.euro)
    let options = try await MoneyFixture.options(context)
    #expect(!options.categories(including: nil).contains { $0.key == MoneyFixture.transport })
    #expect(options.categories(including: MoneyFixture.transport).contains { $0.key == MoneyFixture.transport }, "an expense already filed there keeps it")

    await model.setArchived(MoneyFixture.transport, false)
    _ = try await MoneyFixture.loaded(model.overview, "the restored category") { snapshot in
      snapshot.overview.categories.first { $0.key == MoneyFixture.transport }?.isArchived == false
    }
    let bodies = try await MoneyFixture.bodies(context)
    #expect(
      bodies == [
        .categorySetArchived(try CategoryArchival(categoryId: MoneyFixture.transport, archived: true)),
        .categorySetArchived(try CategoryArchival(categoryId: MoneyFixture.transport, archived: false)),
      ])
  }

  @Test("should refuse to archive uncategorised, writing nothing")
  func refusesPermanentCategories() async throws {
    let context = try await MoneyFixture.context()
    let model = CategoriesModel(context: context)

    await model.setArchived(MoneyFixture.uncategorised, true)

    #expect(model.failure?.headline == String(localized: "Uncategorised and Subscriptions are always kept, so they can’t be archived.", table: "Writing"))
    #expect(try await MoneyFixture.bodies(context).isEmpty)
  }
}
