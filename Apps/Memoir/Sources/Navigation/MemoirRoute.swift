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
}
