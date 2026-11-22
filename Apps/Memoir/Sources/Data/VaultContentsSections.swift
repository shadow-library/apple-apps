import ShadowDesignSystem
import SwiftUI

/// The sets a screen covers, one section each, with how many records of each sort this device holds.
struct VaultContentsSections: View {
  let load: VaultContents.Load

  var body: some View {
    switch load {
    case .loading:
      Section { ProgressView().frame(maxWidth: .infinity) }
    case .failed:
      Section {
        ShadowCallout(
          Text("What this covers couldn’t be counted", tableName: "Data"),
          message: Text("Everything is still included; only the counts are missing.", tableName: "Data"), intent: .warning)
      }
    case .loaded(let contents):
      ForEach(VaultContents.Area.allCases, id: \.self) { area in
        Section {
          ForEach(area.items, id: \.self) { item in
            LabeledContent {
              Text(contents.count(item), format: .number)
            } label: {
              Text(verbatim: DataCopy.item(item))
            }
          }
        } header: {
          Text(verbatim: DataCopy.area(area))
        }
      }
    }
  }
}
