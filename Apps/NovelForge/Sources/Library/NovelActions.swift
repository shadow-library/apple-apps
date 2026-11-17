import NovelForgeCore
import SwiftUI

struct NovelActions: View {
  enum Placement {
    case toolbar
    case contextMenu
  }

  let library: LibraryModel
  let novel: NovelRecord
  let placement: Placement

  var body: some View {
    Button {
      library.present(.edit(novel))
    } label: {
      Label(title: { Text("Edit…", tableName: "Library") }, icon: { Image(systemName: "pencil") })
    }
    Button {
      library.present(.clone(novel))
    } label: {
      Label(title: { Text("Clone…", tableName: "Library") }, icon: { Image(systemName: "doc.on.doc") })
    }
    if placement == .contextMenu { Divider() }
    if novel.archived {
      Button {
        Task { await library.restore(novel.id) }
      } label: {
        Label(title: { Text("Restore", tableName: "Library") }, icon: { Image(systemName: "tray.and.arrow.up") })
      }
    } else {
      Button {
        Task { await library.archive(novel.id) }
      } label: {
        Label(title: { Text("Archive", tableName: "Library") }, icon: { Image(systemName: "archivebox") })
      }
    }
  }
}
