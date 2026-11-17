import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

enum StoryTab: Hashable, CaseIterable {
  case volumes
  case milestones
  case promises
  case secrets

  var title: Text {
    switch self {
    case .volumes: Text("Volumes", tableName: "Story")
    case .milestones: Text("Milestones", tableName: "Story")
    case .promises: Text("Promises", tableName: "Story")
    case .secrets: Text("Secrets", tableName: "Story")
    }
  }

  var newSheet: StorySheet {
    switch self {
    case .volumes: .newVolume
    case .milestones: .newMilestone
    case .promises: .newPromise
    case .secrets: .newSecret
    }
  }

  var newTitle: Text {
    switch self {
    case .volumes: Text("New Volume", tableName: "Story")
    case .milestones: Text("New Milestone", tableName: "Story")
    case .promises: Text("New Promise", tableName: "Story")
    case .secrets: Text("New Secret", tableName: "Story")
    }
  }
}

struct StoryView: View {
  let context: NovelContext
  @State private var model: StoryModel
  @State private var tab = StoryTab.volumes

  init(context: NovelContext) {
    self.context = context
    _model = State(initialValue: StoryModel(context: context))
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker(selection: $tab) {
        ForEach(StoryTab.allCases, id: \.self) { $0.title.tag($0) }
      } label: {
        Text("Section", tableName: "Story")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, Spacing.space4)
      .padding(.vertical, Spacing.space2)
      StoryLoaded(model: model) { structure in
        switch tab {
        case .volumes: VolumesTab(model: model, structure: structure)
        case .milestones: MilestonesTab(model: model, structure: structure)
        case .promises: PromisesTab(model: model, structure: structure)
        case .secrets: SecretsTab(model: model, structure: structure)
        }
      }
    }
    .background(ShadowColor.surfaceApp)
    .navigationTitle(Text(NovelSection.story.title))
    .navigationDestination(for: StoryRoute.self) { route in
      switch route {
      case .volume(let key): VolumeDetailView(model: model, key: key)
      case .milestone(let key): MilestoneDetailView(model: model, key: key)
      case .promise(let promise): PromiseDetailView(model: model, promise: promise)
      case .secret(let key): SecretDetailView(model: model, key: key)
      }
    }
    .toolbar {
      ToolbarItemGroup {
        Button {
          model.present(tab.newSheet)
        } label: {
          Label(title: { tab.newTitle }, icon: { Image(systemName: "plus") })
        }
        .shadowBarItem()
      }
    }
    .task(id: model.generation) { await model.observe() }
    .storyPresentations(model)
  }
}
