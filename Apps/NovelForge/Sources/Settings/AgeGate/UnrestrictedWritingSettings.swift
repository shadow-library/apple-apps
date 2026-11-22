import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// Where the owner confirms their age for unrestricted writing on this device, or withdraws it, and sees what else it waits for. Shown only in builds that
/// have unrestricted writing.
struct UnrestrictedWritingSettings: View {
  let adult: AdultConfirmationModel
  let services: AIServices
  @State private var confirming = false
  @State private var withdrawing = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        ageSection
        offerSection
      }
      .padding(Spacing.space4)
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
    }
    .background(ShadowColor.surfaceApp)
    .sheet(isPresented: $confirming) { AdultConfirmationSheet(adult: adult) {} }
    .confirmationDialog(Text("Withdraw your age confirmation?", tableName: "AgeGate"), isPresented: $withdrawing, titleVisibility: .visible) {
      Button(role: .destructive) {
        adult.withdraw()
      } label: {
        Text("Withdraw", tableName: "AgeGate")
      }
    } message: {
      Text(
        "Unrestricted writing turns off on this device. Chapters and replies already written stay as they are, but this device writes no more unrestricted text until you confirm again.",
        tableName: "AgeGate")
    }
  }

  private var ageSection: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if let day = adult.confirmedOn {
          Text("You confirmed you're 18 or older on \(day.formatted(date: .long, time: .omitted)).", tableName: "AgeGate")
          Button(role: .destructive) {
            withdrawing = true
          } label: {
            Text("Withdraw Confirmation", tableName: "AgeGate")
          }
        } else {
          Text("Unrestricted writing is only for adults. Confirm your age to use it on this device.", tableName: "AgeGate")
          Button {
            confirming = true
          } label: {
            Text("Confirm Age…", tableName: "AgeGate")
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.space3)
    } header: {
      Text("Age", tableName: "AgeGate").shadowFont(.headline)
    } footer: {
      AdultConfirmationText.kept
    }
  }

  private var offerSection: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        if services.settings.assignments.hasUnrestrictedModel {
          Text("A model is chosen for unrestricted writing.", tableName: "AgeGate")
        } else {
          Text("No model is chosen for unrestricted writing yet.", tableName: "AgeGate")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.space3)
    } header: {
      Text("When It's Offered", tableName: "AgeGate").shadowFont(.headline)
    } footer: {
      Text(
        "Unrestricted appears for a novel once a model is chosen, your age is confirmed here and the novel is written in English, the language the safety screen covers.",
        tableName: "AgeGate")
    }
  }
}

/// Leads from the AI settings sheet to unrestricted writing's settings, in builds that have it; the Mac shows them in a tab of Settings instead.
struct UnrestrictedWritingLink: View {
  #if !os(macOS)
    @Environment(AdultConfirmationModel.self) private var adult
    @Environment(AIServices.self) private var services
  #endif

  var body: some View {
    #if !os(macOS)
      if UnrestrictedWriting.isAvailable {
        NavigationLink {
          UnrestrictedWritingSettings(adult: adult, services: services).navigationTitle(Text("Unrestricted Writing", tableName: "AgeGate"))
        } label: {
          Label {
            Text("Unrestricted Writing", tableName: "AgeGate")
          } icon: {
            Image(systemName: "exclamationmark.shield")
          }
        }
      }
    #endif
  }
}
