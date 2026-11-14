import ShadowDesignSystem
import SwiftUI

private let unlocking = "Secrets stay hidden from the writer until the chapter that reveals them is finalized into canon. Readers see wiki entries once they reach that chapter."

struct DisclosureGroupPage: View {
  @State private var first = true
  @State private var second = false
  @State private var third = false
  @State private var long = true

  var body: some View {
    ComponentPage(component: .disclosureGroup) {
      StateSection("Default", note: "A trailing chevron rotates to point down when open and the content animates in with `.smooth`. Reduce Motion swaps movement for a fade.") {
        ShadowGroupedSection {
          DisclosureGroup("How unlocking works", isExpanded: $first) { Text(unlocking) }
          DisclosureGroup("Avoid repeating", isExpanded: $second) { Text("Turn this on and the writer avoids phrases the last three chapters already used.") }
          DisclosureGroup("Content ratings", isExpanded: $third) { Text("Ratings follow the strictest chapter in the book.") }
        }
        .disclosureGroupStyle(.shadow(expandedValue: Text("Expanded"), collapsedValue: Text("Collapsed")))
      }
      StateSection("Collapsed", note: "Keep each heading a clear question or topic; never hide required settings in a closed group.") {
        ShadowGroupedSection {
          DisclosureGroup("How unlocking works", isExpanded: .constant(false)) { Text(unlocking) }
          DisclosureGroup("Avoid repeating", isExpanded: .constant(false)) { Text("Turn this on and the writer avoids phrases the last three chapters already used.") }
        }
        .disclosureGroupStyle(.shadow)
      }
      StateSection("Long text", note: "Headings wrap; the chevron stays on the first line’s centre and the content flows at body size.") {
        ShadowGroupedSection {
          DisclosureGroup("What happens to my secrets and to the readers’ wiki when I finalize a chapter into canon?", isExpanded: $long) {
            Text(unlocking + " " + unlocking)
          }
        }
        .disclosureGroupStyle(.shadow)
      }
      StateSection("Disabled", note: "A disabled group keeps its state and ignores taps.") {
        ShadowGroupedSection {
          DisclosureGroup("Advanced export options", isExpanded: .constant(false)) { Text("Not available on the free plan.") }
            .disabled(true)
        }
        .disclosureGroupStyle(.shadow)
      }
      StateSection("Mixed with other rows", note: "A grouped section holds disclosure groups and plain rows together, outside a List.") {
        ShadowGroupedSection {
          ShadowListRow("Writing tone", value: "Warm", accessory: .chevron) { ShadowSymbolTile(systemImage: "pencil.line") }
          DisclosureGroup("About tone", isExpanded: .constant(true)) { Text("Tone guides the draft’s word choice, not its plot.") }
        }
        .disclosureGroupStyle(.shadow)
      }
    }
  }
}
