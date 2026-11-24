import MemoirCore

/// A place on a navigation stack: a destination's screen, or a detail screen an area pushes. Each area owns its route enum and the view that shows it,
/// so adding a detail screen never touches the shell.
enum MemoirRoute: Hashable {
  case destination(MemoirDestination)
  case quest(QuestRoute)
  case money(MoneyRoute)
  case hero(HeroRoute)
  case log(LogRoute)
  case reflect(ReflectRoute)
  case ask(AskRoute)
  case settings(SettingsRoute)

  var destination: MemoirDestination? {
    guard case .destination(let destination) = self else { return nil }
    return destination
  }

  /// An area's details need that area's module; a reflected record shows as long as History does.
  var requirement: MemoirModuleRequirement {
    switch self {
    case .destination(let destination): destination.requirement
    case .quest: .module(.quests)
    case .money: .module(.money)
    case .hero: .module(.hero)
    case .log: .always
    case .reflect: MemoirDestination.history.requirement
    case .ask: MemoirDestination.ask.requirement
    case .settings: MemoirDestination.settings.requirement
    }
  }
}
