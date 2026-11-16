extension ModelCatalog {
  public static let retirementWarningDays = 30

  public func resolved(available: Set<String>?, on today: CatalogDate) -> CatalogResolution {
    var routes = self.routes
    var notices: [CatalogNotice] = []
    for task in ModelTask.allCases {
      for pace in Pace.allCases {
        guard let route = routes[task]?[pace], !isUsable(route.model, available: available, on: today) else { continue }
        guard let successor = firstUsableSuccessor(of: route.model, available: available, on: today) else {
          append(.unavailable(model: route.model), to: &notices)
          continue
        }
        routes[task]?[pace] = replacement(for: route, with: successor)
        append(.replaced(model: route.model, by: successor.id), to: &notices)
      }
    }
    let inUse = Set(routes.values.flatMap { $0.values.map(\.model) })
    for id in inUse {
      guard let on = model(id)?.retiresOn else { continue }
      let daysLeft = today.days(until: on)
      guard (0...Self.retirementWarningDays).contains(daysLeft) else { continue }
      append(.retiringSoon(model: id, on: on, daysLeft: daysLeft), to: &notices)
    }
    var resolved = self
    resolved.routes = routes
    return CatalogResolution(catalog: resolved, notices: notices.sorted { $0.sortKey.lexicographicallyPrecedes($1.sortKey) })
  }

  private func isUsable(_ id: String, available: Set<String>?, on today: CatalogDate) -> Bool {
    guard let model = model(id) else { return false }
    if let retiresOn = model.retiresOn, retiresOn < today { return false }
    return available?.contains(id) ?? true
  }

  private func firstUsableSuccessor(of id: String, available: Set<String>?, on today: CatalogDate) -> CatalogModel? {
    var visited: Set<String> = [id]
    var pending = (model(id)?.successors ?? []).reversed() as [String]
    while let next = pending.popLast() {
      guard visited.insert(next).inserted else { continue }
      if isUsable(next, available: available, on: today), let model = model(next) { return model }
      pending += (model(next)?.successors ?? []).reversed()
    }
    return nil
  }

  private func replacement(for route: CatalogRoute, with model: CatalogModel) -> CatalogRoute {
    CatalogRoute(model: model.id, effort: route.effort.flatMap(model.nearestEffort(to:)), maxOutputTokens: min(route.maxOutputTokens, model.maxOutputTokens))
  }

  private func append(_ notice: CatalogNotice, to notices: inout [CatalogNotice]) {
    guard !notices.contains(notice) else { return }
    notices.append(notice)
  }
}

extension CatalogNotice {
  fileprivate var sortKey: [String] {
    switch self {
    case .retiringSoon(let model, let on, _): ["0", on.description, model]
    case .replaced(let model, let by): ["1", model, by]
    case .unavailable(let model): ["2", model, ""]
    }
  }
}
