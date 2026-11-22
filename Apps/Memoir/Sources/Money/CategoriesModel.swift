import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

/// memoir-web `CategoriesScreen`: every category with this month's spending, archived and restored by hand; uncategorised and subscriptions always stay.
@MainActor
@Observable
final class CategoriesModel {
  /// `MoneyReads.categories` with the home currency its totals are in, from the same read.
  nonisolated struct Snapshot: Sendable, Equatable {
    let home: CurrencyCode?
    let overview: CategoriesOverview
  }

  let overview = MoneyFeed<Snapshot>()
  private(set) var working: Set<CategoryKey> = []
  private(set) var failure: PresentedError?
  private(set) var notice: String?
  @ObservationIgnored let context: MemoirScreenContext

  init(context: MemoirScreenContext) {
    self.context = context
  }

  func run() async {
    defer { overview.stop() }
    var followed: LocalDate?
    do {
      for try await today in context.observeToday() where today.date != followed {
        followed = today.date
        let stores = context.stores
        let date = today.date
        overview.follow {
          stores.main.observeReads { transaction in
            let book = try MoneyBook.load(from: transaction)
            return Snapshot(home: book.home, overview: try CategoriesOverview.make(book, today: date))
          }
        }
      }
    } catch {
      overview.fail(error)
    }
  }

  func slice(of key: CategoryKey) -> CategorySlice? {
    overview.state.value?.overview.thisMonth?.first { $0.category == key }
  }

  /// This month's total of a category in the home currency; nothing before the vault has one.
  func amount(of slice: CategorySlice?, locale: Locale) -> String {
    guard let home = overview.state.value?.home else { return "" }
    return MoneyText.formatted(slice?.totalMinor ?? 0, home, locale: locale)
  }

  /// Issues `category.setArchived` and keeps the archived flag in the category's record, created with its built-in name when it has none yet.
  func setArchived(_ key: CategoryKey, _ archived: Bool) async {
    guard !working.contains(key) else { return }
    working.insert(key)
    failure = nil
    notice = nil
    defer { working.remove(key) }
    let label = MoneyLabels.storedLabel(key)
    do {
      try await context.writer.write { issuer, transaction in
        try issuer.issue(.categorySetArchived(try CategoryArchival(categoryId: key, archived: archived)), in: &transaction)
        switch try ExpenseCategoryRecord.read(key: .expenseCategory(key), in: transaction) {
        case .readable: try ExpenseCategoryRecord.edit(MemoirKey.expenseCategory(key).ref, in: &transaction) { $0.archived = archived }
        case .absent: try ExpenseCategoryRecord(key: key, label: label, archived: archived).create(in: &transaction)
        case .unreadable(let reason): throw MemoirRecordError.unreadable(MemoirKey.expenseCategory(key).ref, reason)
        }
      }
      notice =
        archived
        ? String(localized: "Archived. It is hidden from new entries and kept in Insights.", table: "Money")
        : String(localized: "Restored.", table: "Money")
    } catch {
      failure = WritingErrors.presented(error)
    }
  }
}
