import Testing

@testable import ShadowSync

@Suite("VaultFormat")
struct VaultFormatTests {
  @Test("should use the four ASCII bytes SLV1 as magic")
  func shouldUseSlv1Magic() {
    #expect(Array(VaultFormat.magic) == [0x53, 0x4C, 0x56, 0x31])
  }

  @Test("should start at format version 1")
  func shouldStartAtVersionOne() {
    #expect(VaultFormat.version == 1)
  }
}
