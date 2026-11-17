import ShadowAI
import Testing

struct ShadowAIWiringTests {
  @Test
  func shouldLinkShadowAIIntoTheCore() {
    #expect(ModelCatalog.currentFormat == 1)
  }
}
