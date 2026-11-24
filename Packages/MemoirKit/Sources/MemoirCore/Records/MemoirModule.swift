public enum MemoirModule: String, CaseIterable, Hashable, Sendable {
  case hero
  case quests
  case money
  case journal
  case meals
  case body
}

extension AccountSettingsRecord {
  public var modules: Set<MemoirModule> {
    Set(MemoirModule.allCases.filter(isEnabled))
  }

  public func isEnabled(_ module: MemoirModule) -> Bool {
    self[module] ?? true
  }

  public mutating func setModule(_ module: MemoirModule, enabled: Bool) {
    self[module] = enabled
  }

  private subscript(module: MemoirModule) -> Bool? {
    get {
      switch module {
      case .hero: moduleHero
      case .quests: moduleQuests
      case .money: moduleMoney
      case .journal: moduleJournal
      case .meals: moduleMeals
      case .body: moduleBody
      }
    }
    set {
      switch module {
      case .hero: moduleHero = newValue
      case .quests: moduleQuests = newValue
      case .money: moduleMoney = newValue
      case .journal: moduleJournal = newValue
      case .meals: moduleMeals = newValue
      case .body: moduleBody = newValue
      }
    }
  }
}
