import Testing

@testable import NovelForgeCore

private func mode(_ value: OrderedJSON?) -> ContentMode? { value?.stringValue.flatMap { ContentMode(rawValue: $0) } }
private func tier(_ value: OrderedJSON?) -> CostTier? { value?.stringValue.flatMap { CostTier(rawValue: $0) } }

struct ChatSelectionParityTests {
  private static let fixture = Result { try ChatFixture.load("selection.json") }

  @Test func shouldShareTheReferenceDefaultsAndGraph() throws {
    let fixture = try Self.fixture.get()
    #expect(chatTurnGraph == fixture["graph"]?.text)
    #expect(defaultCostTier.rawValue == fixture["defaultCostTier"]?.text)
  }

  @Test func shouldChooseEverySelectionAsTheReference() throws {
    for (position, item) in try #require(try Self.fixture.get()["chosen"]).items.enumerated() {
      let turn = item["turn"]
      let project = item["project"]?.objectValue.map { _ in ChatProjectConfig(contentMode: mode(item["project"]?["contentMode"]), costTier: tier(item["project"]?["costTier"])) }
      let result = chatSelection(ChatSelectionOverride(contentMode: mode(turn?["contentMode"]), costTier: tier(turn?["costTier"])), project: project)
      #expect(result.contentMode.rawValue == item["expected"]?["contentMode"]?.text && result.costTier.rawValue == item["expected"]?["costTier"]?.text, "chosen \(position)")
    }
  }

  @Test func shouldReadEveryStoredSelectionAsTheReference() throws {
    var complete = 0
    for (position, item) in try #require(try Self.fixture.get()["stored"]).items.enumerated() {
      let stored = storedChatSelection(costTier: item["costTier"]?.stringValue, contentMode: item["contentMode"]?.stringValue)
      #expect(stored.costTier?.rawValue == item["expected"]?["costTier"]?.stringValue, "tier \(position)")
      #expect(stored.contentMode?.rawValue == item["expected"]?["contentMode"]?.stringValue, "mode \(position)")
      if stored.costTier != nil && stored.contentMode != nil { complete += 1 }
    }
    #expect(complete > 0)
  }
}

// apps/novel-forge-server/tests/refinement/chat-selection.spec.ts:14
struct ChatSelectionSpecTests {
  private let project = ChatProjectConfig(contentMode: .standard, costTier: .performant)

  @Test func shouldTakeTheSelectionFromTheTurnFirst() {
    #expect(chatSelection(ChatSelectionOverride(contentMode: .unrestricted, costTier: .economy), project: project) == ChatSelection(contentMode: .unrestricted, costTier: .economy))
  }

  @Test func shouldTakeTheSelectionFromTheProjectWhenTheTurnHasNone() {
    #expect(chatSelection(ChatSelectionOverride(), project: project) == ChatSelection(contentMode: .standard, costTier: .performant))
  }

  @Test func shouldTakeEachFieldOnItsOwn() {
    #expect(chatSelection(ChatSelectionOverride(costTier: .economy), project: project) == ChatSelection(contentMode: .standard, costTier: .economy))
  }

  @Test func shouldFallBackToStandardAtBalancedWithoutAProjectRow() {
    #expect(chatSelection(ChatSelectionOverride()) == ChatSelection(contentMode: .standard, costTier: .balanced))
  }

  @Test func shouldFollowAnUnrestrictedProjectUnlessTheTurnAsksForStandard() {
    let unrestricted = ChatProjectConfig(contentMode: .unrestricted, costTier: .balanced)
    #expect(chatSelection(ChatSelectionOverride(), project: unrestricted) == ChatSelection(contentMode: .unrestricted, costTier: .balanced))
    #expect(chatSelection(ChatSelectionOverride(contentMode: .standard), project: unrestricted) == ChatSelection(contentMode: .standard, costTier: .balanced))
  }
}
