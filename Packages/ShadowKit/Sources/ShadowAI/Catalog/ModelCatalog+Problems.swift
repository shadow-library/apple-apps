extension ModelCatalog {
  public func problems() -> [String] {
    var found: [String] = []
    var seen = Set<String>()
    for model in models where !seen.insert(model.id).inserted {
      found.append("The model \(model.id) is listed more than once.")
    }
    for model in models {
      for (name, price) in Self.priceList(model.pricing) where price.nanoUSD < 0 {
        found.append("The model \(model.id) has a negative \(name) price.")
      }
      if let longPrompt = model.longPrompt {
        found += problems(inLongPrompt: longPrompt, of: model)
      }
      for successor in model.successors where self.model(successor) == nil {
        found.append("The model \(model.id) names \(successor) as a successor, but \(successor) is not in the catalog.")
      }
      if reachesItself(model.id) {
        found.append("The model \(model.id) is part of a successor cycle.")
      }
    }
    for task in ModelTask.allCases {
      for pace in Pace.allCases {
        guard let route = routes[task]?[pace] else {
          found.append("The \(task.rawValue) task has no route for the \(pace.rawValue) pace.")
          continue
        }
        found += problems(in: route, task: task, pace: pace)
      }
    }
    return found
  }

  private static func priceList(_ pricing: ModelPricing) -> [(String, Cost)] {
    [
      ("input", pricing.input), ("output", pricing.output), ("cache read", pricing.cacheRead),
      ("short cache write", pricing.cacheWriteShort), ("long cache write", pricing.cacheWriteLong),
    ]
  }

  private func problems(inLongPrompt longPrompt: CatalogLongPromptPricing, of model: CatalogModel) -> [String] {
    var found: [String] = []
    if longPrompt.aboveTokens < 1 {
      found.append("The model \(model.id) has a long-prompt threshold below 1.")
    }
    for ((name, price), (_, base)) in zip(Self.priceList(longPrompt.pricing), Self.priceList(model.pricing)) {
      if price.nanoUSD < 0 {
        found.append("The model \(model.id) has a negative long-prompt \(name) price.")
      } else if price < base {
        found.append("The model \(model.id) has a long-prompt \(name) price below its base price, which is suspicious.")
      }
    }
    return found
  }

  private func problems(in route: CatalogRoute, task: ModelTask, pace: Pace) -> [String] {
    let label = "The \(task.rawValue) route at the \(pace.rawValue) pace"
    var found: [String] = []
    if route.maxOutputTokens < 1 {
      found.append("\(label) has an output cap below 1.")
    }
    guard let model = model(route.model) else { return found + ["\(label) uses \(route.model), which is not in the catalog."] }
    if let effort = route.effort, !model.accepts(effort) {
      found.append("\(label) asks for \(effort.rawValue) effort, which \(model.id) does not accept.")
    }
    if route.maxOutputTokens > model.maxOutputTokens {
      found.append("\(label) has an output cap of \(route.maxOutputTokens), above the \(model.maxOutputTokens) that \(model.id) allows.")
    }
    return found
  }

  private func reachesItself(_ id: String) -> Bool {
    var visited = Set<String>()
    var pending = model(id)?.successors ?? []
    while let next = pending.popLast() {
      if next == id { return true }
      guard visited.insert(next).inserted else { continue }
      pending += model(next)?.successors ?? []
    }
    return false
  }
}
