import NovelForgeCore
import ShadowStore
import Testing

struct NovelForgeTests {
  @Test func shouldUseAKindPrefixOutsideTheKernelReservedPrefix() {
    #expect(!NovelForge.kindPrefix.hasPrefix("_"))
    #expect(EntityKind(NovelForge.kindPrefix + "novel") != nil)
  }
}
