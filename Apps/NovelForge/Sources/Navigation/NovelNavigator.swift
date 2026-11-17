import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class NovelNavigator {
  var section: NovelSection? = .overview
  private(set) var paths: [NovelSection: NavigationPath] = [:]

  func show(_ section: NovelSection) {
    self.section = section
  }

  func open(_ section: NovelSection, _ route: some Hashable) {
    paths[section] = NavigationPath([route])
    self.section = section
  }

  func push(_ route: some Hashable) {
    guard let section else { return }
    paths[section, default: NavigationPath()].append(route)
  }

  func pop(_ section: NovelSection) {
    guard var path = paths[section], !path.isEmpty else { return }
    path.removeLast()
    paths[section] = path
  }

  func path(for section: NovelSection) -> Binding<NavigationPath> {
    Binding(get: { self.paths[section] ?? NavigationPath() }, set: { self.paths[section] = $0 })
  }
}

@MainActor
final class NovelNavigators {
  private var navigators: [UUID: NovelNavigator] = [:]

  func navigator(for novel: UUID) -> NovelNavigator {
    if let existing = navigators[novel] { return existing }
    let created = NovelNavigator()
    navigators[novel] = created
    return created
  }

  func prune(keeping novels: Set<UUID>) {
    navigators = navigators.filter { novels.contains($0.key) }
  }
}
