import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct EntityView: View {
  let model: StoryBibleModel
  let key: String
  @State private var observer = ReadObserver<EntityReading>()
  @State private var generation = 0
  @State private var editing: EditTarget?
  @State private var confirmingRemoval = false

  var body: some View {
    content
      .task(id: generation) {
        let store = model.context.store
        let input = EntityReading.Input(novel: model.context.novel, entity: key)
        await observer.run { store.observe(EntityReading.self, input) }
      }
      .sheet(item: $editing) { target in EntityFormSheet(mode: .edit(target.entity), model: model) { _ in } }
  }

  @ViewBuilder
  private var content: some View {
    switch observer.state {
    case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error): BibleReadFailed(error: error) { generation += 1 }
    case .loaded(let reading): loaded(reading)
    }
  }

  @ViewBuilder
  private func loaded(_ reading: EntityReading) -> some View {
    switch reading.presence {
    case .missing: BibleNotFound(subject: .entity, restore: nil)
    case .removed: BibleNotFound(subject: .entity) { Task { await model.restoreEntity(key) } }
    case .unreadable: BibleUnreadable()
    case .live(let entity): details(entity, knowledge: reading.knowledge)
    }
  }

  private func details(_ entity: EntityRecord, knowledge: Derived<[KnowledgeItem]>?) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        header(entity)
        field(entity.type == .known(.character) ? Text("Who they are", tableName: "StoryBible") : Text("About", tableName: "StoryBible"), entity.body)
        if entity.type == .known(.character) || entity.motivation?.isEmpty == false { field(Text("Wants", tableName: "StoryBible"), entity.motivation) }
        field(Text("Appearance", tableName: "StoryBible"), entity.appearance)
        field(Text("Notes", tableName: "StoryBible"), entity.notes)
        if let knowledge { KnowledgeSection(knowledge: knowledge) }
      }
      .padding(Spacing.space6)
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .shadowScreen(.root)
    .navigationTitle(Text(verbatim: entity.name))
    .toolbar {
      ToolbarItemGroup {
        Button {
          editing = EditTarget(entity: entity)
        } label: {
          Label(title: { Text("Edit", tableName: "StoryBible") }, icon: { Image(systemName: "pencil") })
        }
        .shadowBarItem()
        Button(role: .destructive) {
          confirmingRemoval = true
        } label: {
          Label(title: { Text("Remove", tableName: "StoryBible") }, icon: { Image(systemName: "trash") })
        }
        .shadowBarItem()
      }
    }
    .confirmationDialog(Text("Remove this entry?", tableName: "StoryBible"), isPresented: $confirmingRemoval, titleVisibility: .visible) {
      Button(role: .destructive) {
        Task { await model.removeEntity(key, name: entity.name) }
      } label: {
        Text("Remove", tableName: "StoryBible")
      }
    } message: {
      Text("You can restore it right after.", tableName: "StoryBible")
    }
  }

  private func header(_ entity: EntityRecord) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text(verbatim: entity.name).shadowFont(.largeTitle).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
      HStack(spacing: Spacing.space2) {
        switch entity.type {
        case .known(let type): ShadowBadge(Text(type.label))
        case .unknown(let raw): ShadowBadge(Text(verbatim: raw))
        }
        if let significance = entity.significance?.knownSignificance { ShadowBadge(Text(significance.label)) }
        if let status = entity.status, !status.isEmpty { ShadowBadge(Text(verbatim: status)) }
      }
    }
  }

  @ViewBuilder
  private func field(_ title: Text, _ value: String?) -> some View {
    if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        title.shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary).accessibilityAddTraits(.isHeader)
        ProseView(markdown: value)
      }
    }
  }
}

private struct EditTarget: Identifiable {
  let entity: EntityRecord

  var id: String { entity.entity }
}

private struct KnowledgeSection: View {
  let knowledge: Derived<[KnowledgeItem]>

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("What they know", tableName: "StoryBible").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary).accessibilityAddTraits(.isHeader)
      switch knowledge {
      case .unavailable:
        Label(title: { Text("Not up to date on this device", tableName: "StoryBible") }, icon: { Image(systemName: "exclamationmark.triangle") })
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.warningText)
      case .available(let items) where items.isEmpty:
        Text("Nothing recorded yet. Facts they learn in the story appear here.", tableName: "StoryBible").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      case .available(let items):
        ForEach(items) { item in row(item) }
      }
    }
  }

  private func row(_ item: KnowledgeItem) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Text(verbatim: item.text ?? item.fact).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
      HStack(spacing: Spacing.space2) {
        ShadowBadge(Text("Chapter \(item.chapter)", tableName: "StoryBible"))
        if item.status == .provisional { ShadowBadge(Text("Pending finalize", tableName: "StoryBible"), intent: .warning) }
      }
    }
    .accessibilityElement(children: .combine)
  }
}
