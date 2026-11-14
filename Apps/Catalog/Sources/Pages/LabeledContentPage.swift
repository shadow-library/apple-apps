import ShadowDesignSystem
import SwiftUI

struct LabeledContentPage: View {
  var body: some View {
    ComponentPage(component: .labeledContent) {
      StateSection("Default", note: "iPhone and iPad: label leading in text-primary, value trailing in text-secondary. Mac: two columns, labels right-aligned in text-secondary.") {
        ShadowDetailsForm {
          ShadowLabeledContent("Status") { ShadowBadge("Canon", intent: .success, systemImage: "checkmark") }
          ShadowLabeledContent("Words", value: "3,214")
          ShadowLabeledContent("Drafted by", value: "AI · reviewed")
          ShadowLabeledContent("Updated", value: Text(Date.catalogNow, format: .dateTime.day().month(.abbreviated).hour().minute()))
          ShadowLabeledContent("Client ID", identifier: "nf-web-7f3a2c")
        } header: {
          ShadowSectionHeader("Chapter details")
        }
      }
      StateSection("Identifiers", note: "IDs and codes use mono-body and are selectable, so they can be copied. Values never look editable.") {
        ShadowDetailsForm {
          ShadowLabeledContent("Client ID", identifier: "nf-web-7f3a2c")
          ShadowLabeledContent("Secret hash", identifier: "sha256:9b74c9897bac770ffc029102a200c5de")
        }
      }
      StateSection("Long text", note: "Values wrap and stay trailing on touch; at accessibility sizes the layout keeps reading order.") {
        ShadowDetailsForm {
          ShadowLabeledContent("Drafted by", value: "An AI draft reviewed line by line by Mira Vale, then by the Archivist, before it was finalized")
          ShadowLabeledContent("Chapter", value: "The Glass Stair and the Archive of Forgotten Lanterns")
        }
      }
      StateSection("Empty value", note: "Show an en dash rather than a blank, so the row never looks broken.") {
        ShadowDetailsForm {
          ShadowLabeledContent("Reviewed by", value: "–")
          ShadowLabeledContent("Words", value: "3,214")
        }
      }
      StateSection("Large text", note: "Accessibility Dynamic Type grows rows instead of truncating.") {
        ShadowDetailsForm {
          ShadowLabeledContent("Status") { ShadowBadge("Canon", intent: .success, systemImage: "checkmark") }
          ShadowLabeledContent("Drafted by", value: "AI · reviewed")
        }
        .dynamicTypeSize(.accessibility2)
      }
      StateSection("Cards and rows together", note: "One scroll view can mix a card and grouped rows; `ShadowGroupedSection` replaces the nested non-scrolling Form.") {
        ShadowCard {
          Text("Chapter 43").shadowFont(.headline)
          Text("Ash Garden").shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        }
        ShadowDetailsForm {
          ShadowLabeledContent("Words", value: "3,214")
          ShadowLabeledContent("Reading time", value: "14 min")
        }
      }
    }
  }
}
