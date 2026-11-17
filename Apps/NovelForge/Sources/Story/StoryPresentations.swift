import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

extension View {
  func storyPresentations(_ model: StoryModel) -> some View {
    modifier(StoryPresentations(model: model))
  }
}

private struct StoryPresentations: ViewModifier {
  let model: StoryModel

  func body(content: Content) -> some View {
    content
      .sheet(item: binding(\.presenting)) { sheet in sheetContent(sheet) }
      .confirmationDialog(goalTitle, isPresented: flag(\.confirmingGoalMet), titleVisibility: .visible) {
        Button {
          guard let key = model.confirmingGoalMet else { return }
          Task { await model.markGoalMet(key) }
        } label: {
          Text("Mark Goal Met", tableName: "Story")
        }
        Button(role: .cancel) {
        } label: {
          Text("Cancel", tableName: "Story")
        }
      } message: {
        goalMessage
      }
      .confirmationDialog(Text("Drop this promise?", tableName: "Story"), isPresented: flag(\.confirmingDrop), titleVisibility: .visible) {
        Button(role: .destructive) {
          guard let promise = model.confirmingDrop else { return }
          Task { await model.drop(promise) }
        } label: {
          Text("Drop Promise", tableName: "Story")
        }
        Button(role: .cancel) {
        } label: {
          Text("Cancel", tableName: "Story")
        }
      } message: {
        Text("A dropped promise is given up on and no longer expected to pay off. You can reopen it later.", tableName: "Story")
      }
      .alert(Text("That did not work", tableName: "Story"), isPresented: flag(\.failure), presenting: model.failure) { _ in
        Button {
        } label: {
          Text("OK", tableName: "Story")
        }
      } message: { failure in
        failure.error.text
      }
      .alert(Text("Goal met", tableName: "Story"), isPresented: flag(\.advance), presenting: model.advance) { _ in
        Button {
        } label: {
          Text("OK", tableName: "Story")
        }
      } message: { advance in
        advance.message
      }
  }

  private var goalTitle: Text {
    Text("Mark \(model.name(ofVolume: model.confirmingGoalMet)) as met?", tableName: "Story")
  }

  @ViewBuilder
  private var goalMessage: some View {
    if let key = model.confirmingGoalMet, let next = model.volumeActivated(afterMarking: key) {
      Text("\(next) will become the volume you are writing, and new chapters will join it. This cannot be undone from here.", tableName: "Story")
    } else {
      Text("No volume is waiting to start, so none will be active until you add the next one. This cannot be undone from here.", tableName: "Story")
    }
  }

  private func binding<Value>(_ path: ReferenceWritableKeyPath<StoryModel, Value?>) -> Binding<Value?> {
    Binding(
      get: { model[keyPath: path] },
      set: { model[keyPath: path] = $0 })
  }

  private func flag<Value>(_ path: ReferenceWritableKeyPath<StoryModel, Value?>) -> Binding<Bool> {
    Binding(
      get: { model[keyPath: path] != nil },
      set: { if !$0 { model[keyPath: path] = nil } })
  }

  @ViewBuilder
  private func sheetContent(_ sheet: StorySheet) -> some View {
    let structure = model.structure.value
    switch sheet {
    case .newVolume: VolumeFormSheet(model: model, editing: nil)
    case .editVolume(let key): editing(structure?.volume(key)) { VolumeFormSheet(model: model, editing: $0) }
    case .newMilestone: MilestoneFormSheet(model: model, editing: nil)
    case .editMilestone(let key): editing(structure?.milestone(key)) { MilestoneFormSheet(model: model, editing: $0) }
    case .newPromise: PromiseFormSheet(model: model, editing: nil)
    case .editPromise(let promise): editing(structure?.promise(promise)) { PromiseFormSheet(model: model, editing: $0) }
    case .newSecret: SecretFormSheet(model: model, editing: nil)
    case .editSecret(let key): editing(structure?.secret(key)) { SecretFormSheet(model: model, editing: $0) }
    case .reveal(let secret): RevealSheet(model: model, secret: secret)
    }
  }

  @ViewBuilder
  private func editing<Item, Form: View>(_ item: Item?, @ViewBuilder form: (Item) -> Form) -> some View {
    if let item {
      form(item)
    } else {
      StoryNotFound(title: Text("This item no longer exists", tableName: "Story"))
    }
  }
}

extension GoalAdvanceNotice {
  var message: Text {
    guard let activated else { return Text("\(completed) is complete. No volume is active until you add the next one.", tableName: "Story") }
    return Text("\(completed) is complete. \(activated) is now active.", tableName: "Story")
  }
}
