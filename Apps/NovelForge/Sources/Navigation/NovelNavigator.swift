import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class NovelNavigator {
  var section: NovelSection? = .overview {
    didSet { chosen = true }
  }
  var layout: NovelLayout {
    didSet { layoutChanged(from: oldValue) }
  }
  private(set) var paths: [NovelSection: NavigationPath] = [:]
  private(set) var compactPath = NavigationPath()
  @ObservationIgnored private var chosen = false
  /// In compact, how many stops sit below the current section's own: nonzero only after `openAbove`.
  @ObservationIgnored private var sectionDepth = 0
  /// What each `openAbove` covered, so Back to that prefix shows its section again.
  @ObservationIgnored private var covered: [(depth: Int, section: NovelSection, sectionDepth: Int)] = []

  init(layout: NovelLayout = .regular) {
    self.layout = layout
    if layout == .compact { enterCompact() }
  }

  var compactSection: NovelSection { section ?? .chat }

  var compactBinding: Binding<NavigationPath> {
    Binding(
      get: { self.compactPath },
      set: {
        self.compactPath = $0
        while let layer = self.covered.last, $0.count <= layer.depth {
          self.covered.removeLast()
          (self.section, self.sectionDepth) = (layer.section, layer.sectionDepth)
        }
        if $0.isEmpty { self.section = .chat }
      })
  }

  func show(_ section: NovelSection) {
    guard layout == .compact else {
      self.section = section
      return
    }
    guard section != compactSection || section == .chat else { return }
    self.section = section
    replaceCompactPath(Self.stops(for: section))
  }

  func open(_ section: NovelSection, _ route: some Hashable) {
    self.section = section
    guard layout == .compact else {
      paths[section] = NavigationPath([route])
      return
    }
    var path = Self.stops(for: section)
    path.append(route)
    replaceCompactPath(path)
  }

  /// `open`, except that in compact the stops already shown stay beneath the section, so Back returns to them with their section.
  func openAbove(_ section: NovelSection, _ route: some Hashable) {
    guard layout == .compact else { return open(section, route) }
    covered.append((compactPath.count, compactSection, sectionDepth))
    sectionDepth = compactPath.count
    self.section = section
    if section != .chat { compactPath.append(CompactStop.section(section)) }
    compactPath.append(route)
  }

  func push(_ route: some Hashable) {
    guard layout == .compact else {
      guard let section else { return }
      paths[section, default: NavigationPath()].append(route)
      return
    }
    compactPath.append(route)
  }

  func pop(_ section: NovelSection) {
    guard layout == .compact else {
      guard var path = paths[section], !path.isEmpty else { return }
      path.removeLast()
      paths[section] = path
      return
    }
    guard section == compactSection, compactPath.count > rootDepth(of: section) else { return }
    compactPath.removeLast()
  }

  func isAtRoot(_ section: NovelSection) -> Bool {
    guard layout == .compact else { return paths[section]?.isEmpty ?? true }
    return section != compactSection || compactPath.count <= rootDepth(of: section)
  }

  func path(for section: NovelSection) -> Binding<NavigationPath> {
    Binding(get: { self.paths[section] ?? NavigationPath() }, set: { self.paths[section] = $0 })
  }

  private func layoutChanged(from old: NovelLayout) {
    guard layout != old else { return }
    if layout == .compact { enterCompact() } else { replaceCompactPath(NavigationPath()) }
  }

  private func enterCompact() {
    if !chosen { section = .chat }
    let current = compactSection
    section = current
    paths[current] = nil
    replaceCompactPath(Self.stops(for: current))
  }

  private func replaceCompactPath(_ path: NavigationPath) {
    compactPath = path
    sectionDepth = 0
    covered = []
  }

  private func rootDepth(of section: NovelSection) -> Int { sectionDepth + Self.stops(for: section).count }

  private static func stops(for section: NovelSection) -> NavigationPath {
    section == .chat ? NavigationPath() : NavigationPath([CompactStop.section(section)])
  }
}

@MainActor
final class NovelNavigators {
  var layout = NovelLayout.regular {
    didSet { for navigator in navigators.values { navigator.layout = layout } }
  }
  private var navigators: [UUID: NovelNavigator] = [:]

  func navigator(for novel: UUID) -> NovelNavigator {
    if let existing = navigators[novel] { return existing }
    let created = NovelNavigator(layout: layout)
    navigators[novel] = created
    return created
  }

  func prune(keeping novels: Set<UUID>) {
    navigators = navigators.filter { novels.contains($0.key) }
  }
}
