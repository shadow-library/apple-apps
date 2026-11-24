import ShadowCore

public enum ModuleSelectionError: ShadowError, Hashable {
  case empty
  case questsNeedHero
  case heroNeedsQuestsOrMoney

  public var code: String {
    switch self {
    case .empty: "memoir_modules.empty"
    case .questsNeedHero: "memoir_modules.quests_need_hero"
    case .heroNeedsQuestsOrMoney: "memoir_modules.hero_needs_quests_or_money"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .empty: "At least one module stays on."
    case .questsNeedHero: "Quests need the Hero module."
    case .heroNeedsQuestsOrMoney: "The Hero module needs Quests or Money."
    }
  }
}

/// The modules a vault shows: never empty, quests only with hero, and hero only with quests or money.
public struct ModuleSelection: Sendable, Hashable {
  public static let all = ModuleSelection(validated: Set(MemoirModule.allCases))

  public let modules: Set<MemoirModule>

  public init(_ modules: Set<MemoirModule>) throws(ModuleSelectionError) {
    if let refusal = Self.refusal(of: modules) { throw refusal }
    self.init(validated: modules)
  }

  /// What the settings record says, made valid. Two devices can each make a valid change whose merge is not valid; such a merge reads by only ever
  /// turning modules on, never off, so nothing the record shows on is hidden: quests on turns hero on, hero on without quests or money turns money on,
  /// and nothing on reads as every module on. No settings record, or one this version cannot read, is every module on.
  public init(settings: AccountSettingsRecord?) {
    var modules = settings?.modules ?? Set(MemoirModule.allCases)
    if modules.isEmpty { modules = Set(MemoirModule.allCases) }
    if modules.contains(.quests) { modules.insert(.hero) }
    if modules.contains(.hero), !modules.contains(.quests) { modules.insert(.money) }
    self.init(validated: modules)
  }

  private init(validated modules: Set<MemoirModule>) {
    assert(Self.refusal(of: modules) == nil, "a selection is valid")
    self.modules = modules
  }

  public func contains(_ module: MemoirModule) -> Bool {
    modules.contains(module)
  }

  public func setting(_ module: MemoirModule, enabled: Bool) throws(ModuleSelectionError) -> ModuleSelection {
    try setting([module: enabled])
  }

  /// Every change at once, so a step valid only as a whole (Hero and Quests on beside Journal alone) is accepted.
  public func setting(_ changes: [MemoirModule: Bool]) throws(ModuleSelectionError) -> ModuleSelection {
    var modules = modules
    for (module, enabled) in changes {
      if enabled { modules.insert(module) } else { modules.remove(module) }
    }
    return try ModuleSelection(modules)
  }

  private static func refusal(of modules: Set<MemoirModule>) -> ModuleSelectionError? {
    if modules.isEmpty { return .empty }
    if modules.contains(.quests), !modules.contains(.hero) { return .questsNeedHero }
    if modules.contains(.hero), !modules.contains(.quests), !modules.contains(.money) { return .heroNeedsQuestsOrMoney }
    return nil
  }
}
