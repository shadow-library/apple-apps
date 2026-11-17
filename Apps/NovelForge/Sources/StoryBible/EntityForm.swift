import Foundation
import NovelForgeCore
import Observation

enum EntityFormMode: Equatable {
  case create(type: EntityType)
  case edit(EntityRecord)
}

@MainActor
@Observable
final class EntityForm {
  let mode: EntityFormMode
  var type: EntityType
  var name: String
  var key = ""
  var significance: EntitySignificance
  var status: String
  var body: String
  var motivation: String
  var appearance: String
  var notes: String
  private(set) var keyEdited = false
  private(set) var failure: PresentedError?
  private(set) var isSubmitting = false

  init(mode: EntityFormMode) {
    self.mode = mode
    switch mode {
    case .create(let type):
      self.type = type
      name = ""
      significance = .minor
      status = ""
      body = ""
      motivation = ""
      appearance = ""
      notes = ""
    case .edit(let entity):
      type = entity.type.knownType ?? .concept
      name = entity.name
      significance = entity.significance?.knownSignificance ?? .minor
      status = entity.status ?? ""
      body = entity.body ?? ""
      motivation = entity.motivation ?? ""
      appearance = entity.appearance ?? ""
      notes = entity.notes ?? ""
    }
  }

  var isCreating: Bool {
    guard case .create = mode else { return false }
    return true
  }

  var showsMotivation: Bool { type == .character || !motivation.isEmpty }
  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  var resolvedKey: String { keyEdited ? key.trimmingCharacters(in: .whitespacesAndNewlines) : BibleKey.slug(from: name) }

  var keyIssue: String? {
    guard isCreating, !name.isEmpty || keyEdited, resolvedKey.isEmpty else { return nil }
    return String(localized: "Use at least one letter or digit.", table: "StoryBible")
  }

  var hasChanges: Bool {
    switch mode {
    case .create: !trimmedName.isEmpty || [status, body, motivation, appearance, notes].contains { !$0.isEmpty }
    case .edit(let entity): trimmedName != entity.name || details(against: entity) != EntityDetails()
    }
  }

  var canSubmit: Bool {
    guard !isSubmitting, !trimmedName.isEmpty else { return false }
    return isCreating ? !resolvedKey.isEmpty : hasChanges
  }

  func editKey(_ text: String) {
    keyEdited = true
    key = text
  }

  func edited() {
    failure = nil
  }

  func submit(using model: StoryBibleModel) async -> String? {
    guard canSubmit else { return nil }
    isSubmitting = true
    failure = nil
    defer { isSubmitting = false }
    do {
      switch mode {
      case .create:
        return try await model.createEntity(key: resolvedKey, type: type, name: trimmedName, details: createDetails)
      case .edit(let entity):
        try await model.editEntity(key: entity.entity, name: trimmedName == entity.name ? nil : trimmedName, details: details(against: entity))
        return entity.entity
      }
    } catch {
      failure = StoryBibleErrors.presented(error)
      return nil
    }
  }

  private var createDetails: EntityDetails {
    EntityDetails(
      significance: significance, status: Self.nonEmpty(status), notes: Self.nonEmpty(notes), motivation: Self.nonEmpty(motivation), body: Self.nonEmpty(body),
      appearance: Self.nonEmpty(appearance))
  }

  private func details(against entity: EntityRecord) -> EntityDetails {
    EntityDetails(
      significance: significance == entity.significance?.knownSignificance ?? .minor ? nil : significance, status: Self.changed(status, from: entity.status),
      notes: Self.changed(notes, from: entity.notes), motivation: Self.changed(motivation, from: entity.motivation), body: Self.changed(body, from: entity.body),
      appearance: Self.changed(appearance, from: entity.appearance))
  }

  private static func nonEmpty(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func changed(_ text: String, from stored: String?) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    return trimmed
  }
}
