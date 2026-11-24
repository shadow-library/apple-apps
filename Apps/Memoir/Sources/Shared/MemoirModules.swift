import Foundation
import MemoirCore
import OSLog
import Observation
import ShadowAppShell
import ShadowCore
import ShadowStore

/// The modules the vault shows, as MemoirCore reads them from the settings record (`ModuleSelection(settings:)`), followed after every main-store
/// commit so a change made in Settings or synced in from another device reshapes the shell at once. No record, or one this build cannot read, shows
/// every module, as the demo's seeded record does.
@MainActor
@Observable
final class MemoirModules {
  enum Standing: Equatable {
    case reading
    case read(ModuleSelection)
  }

  private(set) var standing = Standing.reading

  var selection: ModuleSelection {
    guard case .read(let selection) = standing else { return .all }
    return selection
  }

  func shows(_ route: MemoirRoute) -> Bool { route.requirement.isMet(by: selection) }

  /// A read that fails shows every module, whose screens say what went wrong, rather than hiding data; a later failure keeps what was read.
  func run(stores: MemoirStores) async {
    do {
      for try await selection in stores.main.observeReads({ transaction in try Self.selection(in: transaction) }) where standing != .read(selection) {
        standing = .read(selection)
      }
    } catch is CancellationError {
      return
    } catch {
      Self.logger.error("The modules could not be read code=\((error as? any ShadowError)?.code ?? "unknown", privacy: .public)")
      if case .reading = standing { standing = .read(.all) }
    }
  }

  nonisolated static func selection(in transaction: ReadTransaction) throws(StoreError) -> ModuleSelection {
    ModuleSelection(settings: try AccountSettingsRecord.read(key: .accountSettings, in: transaction).entry?.record)
  }

  private static let logger = Logger(subsystem: AppIdentity.memoir.id, category: "modules")
}
