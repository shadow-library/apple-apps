import SwiftUI
import Testing

@testable import ShadowDesignSystem

@Suite("Avatar initials")
struct ShadowInitialsTests {
  @Test(
    "should take the first and last word initials",
    arguments: [("Mira Vale", "MV"), ("Mira Anne Vale", "MV"), ("  mira   vale ", "MV"), ("Anne-Marie Smith", "AS"), ("(admin) team", "AT"), ("1st place", "1P")])
  func words(name: String, expected: String) {
    #expect(ShadowInitials.make(from: name) == expected)
  }

  @Test("should take one initial from a single name", arguments: [("Madonna", "M"), ("ana@example.com", "A"), ("ßeta", "S"), ("élan", "É")])
  func single(name: String, expected: String) {
    #expect(ShadowInitials.make(from: name) == expected)
  }

  @Test("should return nothing when there is no usable character", arguments: ["", "   ", "…", "- _ ."])
  func empty(name: String) {
    #expect(ShadowInitials.make(from: name).isEmpty)
  }

  @Test("should keep an emoji as one initial, including joined sequences")
  func emoji() {
    #expect(ShadowInitials.make(from: "🦊 Fox") == "🦊F")
    #expect(ShadowInitials.make(from: "🦊") == "🦊")
    #expect(ShadowInitials.make(from: "👩🏽‍🚀 Ada") == "👩🏽‍🚀A")
    #expect(ShadowInitials.make(from: "🇳🇱 Team") == "🇳🇱T")
  }

  @Test("should use the first character of an unspaced CJK name and both words when spaced")
  func cjk() {
    #expect(ShadowInitials.make(from: "山田太郎") == "山")
    #expect(ShadowInitials.make(from: "김민수") == "김")
    #expect(ShadowInitials.make(from: "山田 太郎") == "山太")
    #expect(ShadowInitials.make(from: "李 小龍") == "李小")
  }

  @Test("should keep right-to-left initials in reading order")
  func rightToLeft() {
    #expect(ShadowInitials.make(from: "مريم خالد") == "مخ")
  }
}

@Suite("Avatar tint")
struct ShadowAvatarTintTests {
  @Test("should be deterministic across calls and insensitive to case and padding")
  func deterministic() {
    #expect(ShadowAvatarTint.automatic(for: "Mira Vale") == .chart(6))
    #expect(ShadowAvatarTint.automatic(for: "  mira vale ") == .chart(6))
    #expect(ShadowAvatarTint.automatic(for: "Shadow Library") == .chart(5))
  }

  @Test("should stay within the eight chart slots and use all of them")
  func distribution() {
    let slots = Set(
      (0..<400).compactMap { index -> Int? in
        guard case .chart(let slot) = ShadowAvatarTint.automatic(for: "member-\(index)") else { return nil }
        return slot
      })
    #expect(slots == Set(1...ShadowAvatarTint.chartCount))
  }

  @Test("should spread a handful of short names over every slot")
  func spreadsShortSeeds() {
    let names = ["Ada Lovelace", "Hana Kim", "Jon Reyes", "Arjun Rao", "Grace Hopper", "Mira Vale", "Priya Nair", "Wen Zhao"]
    let slots = Set(
      names.compactMap { name -> Int? in
        guard case .chart(let slot) = ShadowAvatarTint.automatic(for: name) else { return nil }
        return slot
      })
    #expect(slots == Set(1...ShadowAvatarTint.chartCount))
  }

  @Test("should clamp out-of-range chart slots to a real token", arguments: [-3, 0, 9, 99])
  func clamps(slot: Int) {
    #expect(ShadowAvatarTint.chart(slot).chartBackground != nil)
  }
}

@Suite("Avatar group")
struct ShadowAvatarGroupLayoutTests {
  @Test(
    "should collapse the rest into a +n chip only when it hides at least two",
    arguments: [(7, 3, 3, 4), (5, 3, 3, 2), (4, 3, 4, 0), (3, 3, 3, 0), (0, 3, 0, 0), (2, 0, 2, 0), (9, -1, 1, 8)])
  func layout(total: Int, maximum: Int, visible: Int, overflow: Int) {
    let layout = ShadowAvatarGroupLayout(total: total, maximumVisible: maximum)
    #expect(layout.visibleCount == visible)
    #expect(layout.overflow == overflow)
  }
}

@Suite("Avatar tint contrast")
struct ShadowAvatarTintContrastTests {
  @Test("should keep white initials at 4.5:1 on every chart tint in both themes", arguments: Array(1...ShadowAvatarTint.chartCount), ColorScheme.allCases)
  func contrast(slot: Int, scheme: ColorScheme) throws {
    let background = try #require(ShadowAvatarTint.chart(slot).chartBackground)
    let rgba = scheme == .dark ? background.dark : background.light
    let ratio = ShadowColorToken.onAccent.rgba(for: scheme).contrastRatio(against: rgba)
    #expect(ratio >= 4.5, "chart \(slot) in \(scheme) is \(ratio):1")
  }

  @Test("should cap the group overflow label at 99+ with a single plus sign")
  func overflowText() {
    #expect(ShadowAvatarGroupLayout(total: 7, maximumVisible: 3).overflowText == "+4")
    #expect(ShadowAvatarGroupLayout(total: 102, maximumVisible: 3).overflowText == "+99")
    #expect(ShadowAvatarGroupLayout(total: 103, maximumVisible: 3).overflowText == "99+")
    #expect(ShadowAvatarGroupLayout(total: 128, maximumVisible: 3).overflowText == "99+")
    #expect(ShadowAvatarGroupLayout(total: 128, maximumVisible: 3).overflowText.filter { $0 == "+" }.count == 1)
  }
}
