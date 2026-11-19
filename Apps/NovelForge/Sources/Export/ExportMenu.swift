import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

/// apps/novel-forge-web/src/routes/novels/$novelId/overview.tsx:306-318 offers the .novel package; the manuscript is the core's other export. Nothing is sent to a model.
struct ExportMenu: View {
  let model: ExportModel
  let title: String

  var body: some View {
    Menu {
      Button {
        Task { await model.prepare(.manuscript, title: title) }
      } label: {
        Label(title: { Text("Export Manuscript…", tableName: "Export") }, icon: { Image(systemName: "doc.text") })
      }
      Button {
        Task { await model.prepare(.package, title: title) }
      } label: {
        Label(title: { Text("Export as .novel Package…", tableName: "Export") }, icon: { Image(systemName: "shippingbox") })
      }
    } label: {
      Label(title: { Text("Export", tableName: "Export") }, icon: { Image(systemName: "square.and.arrow.up") })
    }
    .disabled(model.isPreparing)
  }
}

extension View {
  func novelExporter(_ model: ExportModel) -> some View {
    modifier(NovelExporter(model: model))
  }
}

private struct NovelExporter: ViewModifier {
  @Bindable var model: ExportModel

  func body(content: Content) -> some View {
    content
      .fileExporter(
        isPresented: $model.isExporting, document: model.prepared?.document ?? ExportDocument(), contentType: model.prepared?.type ?? ExportDocument.markdown,
        defaultFilename: model.prepared?.filename
      ) { _ in model.finish() }
      .alert(
        Text(verbatim: model.failure?.headline ?? ""), isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.dismissFailure() } }), presenting: model.failure
      ) { _ in
        Button {
          model.dismissFailure()
        } label: {
          Text("OK", tableName: "Export")
        }
      } message: { failure in
        if let detail = failure.detail { Text(verbatim: detail) }
      }
  }
}
