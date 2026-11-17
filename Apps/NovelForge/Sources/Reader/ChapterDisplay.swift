import Foundation
import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

enum ChapterDisplay {
  static func number(_ chapter: Int) -> String {
    String(format: "%02d", chapter)
  }

  static func heading(_ chapter: Int) -> Text {
    Text("Chapter \(chapter)", tableName: "Reader")
  }

  static func title(_ title: String?) -> String? {
    guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
  }

  static func stage(of row: ChapterRow) -> (label: Text, systemImage: String, color: Color) {
    if row.stage != .final, row.stale != nil { return (Text("Stale", tableName: "Reader"), "exclamationmark.triangle", ShadowColor.warningText) }
    switch row.stage {
    case .planned: return (Text("Planned", tableName: "Reader"), "circle.dashed", ShadowColor.textSecondary)
    case .drafted: return (Text("Drafted", tableName: "Reader"), "pencil.line", ShadowColor.infoText)
    case .approved: return (Text("Approved", tableName: "Reader"), "checkmark.circle", ShadowColor.successText)
    case .final: return (Text("Final", tableName: "Reader"), "checkmark.seal.fill", ShadowColor.successText)
    }
  }

  static func staleReason(_ cause: StaleCause) -> Text {
    switch cause {
    case .unrecorded: Text("This draft does not record what it was written against.", tableName: "Reader")
    case .canonReplaced(let chapter): Text("The final text of chapter \(chapter) was replaced after this draft was written.", tableName: "Reader")
    case .ancestorDraft(let chapter, _): Text("Chapter \(chapter) changed after this draft was written.", tableName: "Reader")
    case .ancestorKnowledge(let chapter, true): Text("Chapter \(chapter) lost its approval.", tableName: "Reader")
    case .ancestorKnowledge(let chapter, false): Text("The plan of chapter \(chapter) changed what its cast learns.", tableName: "Reader")
    case .reveal: Text("A reveal in this chapter's plan no longer holds.", tableName: "Reader")
    }
  }

  static func source(_ source: DraftSource?) -> Text {
    guard let source else { return Text("Unknown source", tableName: "Reader") }
    switch source {
    case .generated: return Text("Generated", tableName: "Reader")
    case .patched: return Text("Patched", tableName: "Reader")
    case .rewritten: return Text("Rewritten", tableName: "Reader")
    case .revised: return Text("Revised", tableName: "Reader")
    case .imported: return Text("Imported", tableName: "Reader")
    case .handEdited: return Text("Hand edited", tableName: "Reader")
    case .chatEdited: return Text("Edited in chat", tableName: "Reader")
    case .amended: return Text("Amended", tableName: "Reader")
    case .restored: return Text("Restored", tableName: "Reader")
    case .passageRewritten: return Text("Passage rewritten", tableName: "Reader")
    }
  }
}
