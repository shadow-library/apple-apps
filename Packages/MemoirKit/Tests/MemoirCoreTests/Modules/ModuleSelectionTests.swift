import Testing

@testable import MemoirCore

@Suite("Memoir module selection", TestTimeLimit.property)
struct ModuleSelectionTests {
  private static let combinations: [Set<MemoirModule>] = (0..<(1 << MemoirModule.allCases.count)).map { mask in
    Set(MemoirModule.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
  }

  private static func expectedRefusal(_ modules: Set<MemoirModule>) -> ModuleSelectionError? {
    if modules.isEmpty { return .empty }
    if modules.contains(.quests) && !modules.contains(.hero) { return .questsNeedHero }
    if modules.contains(.hero) && !modules.contains(.quests) && !modules.contains(.money) { return .heroNeedsQuestsOrMoney }
    return nil
  }

  private static func settings(_ modules: Set<MemoirModule>, onAsNil: Bool) throws -> AccountSettingsRecord {
    let euro = try MemoirStoreFixture.currency("EUR")
    var settings = AccountSettingsRecord(defaultCurrency: euro, enabledCurrencies: [euro])
    for module in MemoirModule.allCases where !(onAsNil && modules.contains(module)) { settings.setModule(module, enabled: modules.contains(module)) }
    return settings
  }

  @Test func shouldAcceptExactlyTheCombinationsTheLawsAllowAndNameWhatIsMissing() {
    #expect(Self.combinations.count == 64 && Set(Self.combinations).count == 64)
    for modules in Self.combinations {
      let expected = Self.expectedRefusal(modules)
      do throws(ModuleSelectionError) {
        let selection = try ModuleSelection(modules)
        #expect(expected == nil, "\(modules) was accepted")
        #expect(selection.modules == modules)
      } catch {
        #expect(error == expected, "\(modules) refused as \(error.code)")
      }
    }
  }

  @Test func shouldReadEveryStoredCombinationAsAValidSelectionThatHidesNothingTheRecordShows() throws {
    for modules in Self.combinations {
      for onAsNil in [false, true] {
        let read = ModuleSelection(settings: try Self.settings(modules, onAsNil: onAsNil))
        #expect(Self.expectedRefusal(read.modules) == nil, "\(modules) read as the invalid \(read.modules)")
        #expect(read.modules.isSuperset(of: modules))
        if Self.expectedRefusal(modules) == nil { #expect(read.modules == modules, "a valid \(modules) reads as itself") }
      }
    }
  }

  @Test func shouldMakeAMergedInvalidSelectionValidByTheDocumentedRule() throws {
    let read = { (modules: Set<MemoirModule>) in ModuleSelection(settings: try Self.settings(modules, onAsNil: false)).modules }
    #expect(try read([.quests, .journal]) == [.hero, .quests, .journal], "quests turn hero on")
    #expect(try read([.hero]) == [.hero, .money], "hero without quests or money turns money on")
    #expect(try read([.hero, .meals]) == [.hero, .money, .meals])
    #expect(try read([]) == Set(MemoirModule.allCases), "nothing on is every module on")
    #expect(ModuleSelection(settings: nil) == .all)
  }

  @Test func shouldToggleOneModuleOnlyIntoAValidSelection() throws {
    let moneyOnly = try ModuleSelection([.money])
    #expect(try moneyOnly.setting(.hero, enabled: true).modules == [.hero, .money])
    #expect(throws: ModuleSelectionError.questsNeedHero) { try moneyOnly.setting(.quests, enabled: true) }
    #expect(throws: ModuleSelectionError.empty) { try moneyOnly.setting(.money, enabled: false) }
    #expect(throws: ModuleSelectionError.heroNeedsQuestsOrMoney) { try ModuleSelection([.hero, .money]).setting(.money, enabled: false) }
    #expect(try ModuleSelection.all.setting(.quests, enabled: false).modules == [.hero, .money, .journal, .meals, .body])
  }

  @Test func shouldGiveEachRefusalItsOwnCode() {
    let codes = [ModuleSelectionError.empty, .questsNeedHero, .heroNeedsQuestsOrMoney].map(\.code)
    #expect(Set(codes).count == 3 && codes.allSatisfy { $0.hasPrefix("memoir_modules.") })
  }
}
