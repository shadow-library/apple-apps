import ShadowDesignSystem
import SwiftUI

struct AvatarPage: View {
  private static let unreachable = URL(filePath: "/nonexistent/avatar.png")
  private static let people = ["Ada Lovelace", "Grace Hopper", "Mira Vale", "Jon Reyes", "Sam Lee", "Priya Nair", "Tomás Ortega", "Wen Zhao"]
  private static let members = ["Ada Lovelace", "Mira Vale", "Jon Reyes", "Sam Lee", "Priya Nair", "Tomás Ortega", "Wen Zhao"].map { ShadowAvatarMember(id: $0, name: $0) }

  var body: some View {
    ComponentPage(component: .avatar) {
      StateSection("Sizes", note: "22, 28, 40 and 64pt circles. Initials are semibold, two at most, and scale with Dynamic Type up to the accessibility sizes.") {
        HStack(alignment: .center, spacing: Spacing.space4) {
          ShadowAvatar(name: "Ana López", size: .large, tint: .accent)
          ShadowAvatar(name: "Mira Vale", tint: .accent, presence: .online, presenceLabel: Text("Online"))
          ShadowAvatar(name: "Jon Reyes", size: .small, tint: .neutral)
          ShadowAvatar(name: "Sam Lee", size: .extraSmall, tint: .solid)
        }
        .shadowCard()
      }
      StateSection(
        "Initials tint", note: "With no tint chosen, each person gets one of the eight chart colours from their id or name, so the same person always has the same colour."
      ) {
        ShadowFlowLayout(spacing: Spacing.space3, lineSpacing: Spacing.space3) {
          ForEach(Self.people, id: \.self) { ShadowAvatar(name: $0) }
        }
        .shadowCard()
      }
      StateSection("Spec tints and organisations", note: "Accent-soft is the brand tint for people, warm marks a second group, and organisations use neutral-solid.") {
        HStack(spacing: Spacing.space3) {
          ShadowAvatar(name: "Ana López", tint: .accent)
          ShadowAvatar(name: "Mira Vale", tint: .warm)
          ShadowAvatar(name: "Jon Reyes", tint: .neutral)
          ShadowAvatar(name: "Shadow Library", kind: .organization)
          ShadowAvatar(name: "Synapse", kind: .organization, tint: .neutral)
        }
        .shadowCard()
      }
      StateSection(
        "Images and placeholder",
        note: "A caller-supplied Image fills the circle; a remote image shows initials until it loads and when it fails. With no name the avatar falls back to a symbol."
      ) {
        HStack(spacing: Spacing.space3) {
          ShadowAvatar(name: "Mira Vale", source: .image(SamplePortrait.image(ShadowColor.chart1)))
          ShadowAvatar(name: "Jon Reyes", source: .image(SamplePortrait.image(ShadowColor.chart5)), presence: .online, presenceLabel: Text("Online"))
          ShadowAvatar(name: "Sam Lee", source: .url(Self.unreachable))
          ShadowAvatar(name: "")
          ShadowAvatar(name: "", kind: .organization)
        }
        .shadowCard()
      }
      StateSection(
        "Presence",
        note:
          "A dot ringed in the surface colour: online, away, busy and offline. Offline is hollow and busy carries a bar, so the dot is not colour alone; the state is also announced."
      ) {
        HStack(spacing: Spacing.space4) {
          ShadowAvatar(name: "Ada Lovelace", presence: .online, presenceLabel: Text("Online"))
          ShadowAvatar(name: "Grace Hopper", presence: .away, presenceLabel: Text("Away"))
          ShadowAvatar(name: "Mira Vale", presence: .busy, presenceLabel: Text("Busy"))
          ShadowAvatar(name: "Jon Reyes", presence: .offline, presenceLabel: Text("Offline"))
          ShadowAvatar(name: "Priya Nair", size: .large, presence: .online, presenceLabel: Text("Online"))
        }
        .shadowCard()
      }
      StateSection("Groups", note: "Avatars overlap by 8pt inside a ring; the rest collapse into a +n chip, and VoiceOver reads one summary.") {
        VStack(alignment: .leading, spacing: Spacing.space4) {
          HStack(spacing: Spacing.space3) {
            ShadowAvatarGroup(Self.members, maximumVisible: 3, summary: Text("7 members of Shadow Library"))
            Text("7 members of Shadow Library")
              .shadowFont(.footnote)
              .foregroundStyle(ShadowColor.textSecondary)
          }
          ShadowAvatarGroup(Array(Self.members.prefix(3)), size: .medium)
          ShadowAvatarGroup(Array(Self.members.prefix(4)), size: .small)
          ShadowAvatarGroup(Array(Self.members.prefix(3)), totalCount: 128, size: .small)
        }
        .shadowCard()
      }
      StateSection("Long and unusual names", note: "Initials come from the first and last word; emoji, CJK and right-to-left names are handled.") {
        ShadowFlowLayout(spacing: Spacing.space3, lineSpacing: Spacing.space3) {
          ForEach(["Alexandria Ocasio-Cortez of the Shadow Library", "🦊 Fox", "山田 太郎", "김민수", "مريم خالد", "madonna"], id: \.self) { ShadowAvatar(name: $0) }
        }
        .shadowCard()
      }
      StateSection("Disabled") {
        HStack(spacing: Spacing.space3) {
          ShadowAvatar(name: "Mira Vale", presence: .online, presenceLabel: Text("Online"))
          ShadowAvatar(name: "Shadow Library", kind: .organization)
        }
        .disabled(true)
        .shadowCard()
      }
      StateSection("Light and dark") {
        SchemePair {
          HStack(spacing: Spacing.space2) {
            ShadowAvatar(name: "Ana López", tint: .accent)
            ShadowAvatar(name: "Mira Vale", presence: .online, presenceLabel: Text("Online"))
            ShadowAvatar(name: "Shadow Library", kind: .organization)
            ShadowAvatarGroup(Array(Self.members.prefix(3)), totalCount: 7, maximumVisible: 2)
          }
        }
      }
    }
  }
}
