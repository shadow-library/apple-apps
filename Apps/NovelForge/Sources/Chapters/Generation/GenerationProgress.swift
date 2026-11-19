import Foundation
import ShadowJobs

nonisolated struct GenerationStepRow: Equatable, Sendable, Identifiable {
  enum State: Equatable, Sendable {
    case done
    case current
    case pending
  }

  let name: String
  let state: State

  var id: String { name }
}

/// The order of GenerationStep (Pipelines/Generation/GenerationSteps.swift); repair and rewrite are alternatives the run branches into.
nonisolated enum GenerationProgress {
  private static let order = ["pin", "draft", "expand", "title", "save", "checks", "judge", "repair", "rewrite", "finish"]
  private static let always = ["draft", "expand", "title", "save", "checks", "judge", "finish"]

  static func rows(at step: AttemptStep?) -> [GenerationStepRow] {
    guard let name = step?.name, let position = order.firstIndex(of: name) else { return always.map { GenerationStepRow(name: $0, state: .pending) } }
    let shown = order.filter { always.contains($0) || $0 == name }.filter { $0 != "pin" || name == "pin" }
    return shown.map { row in
      let at = order.firstIndex(of: row) ?? 0
      return GenerationStepRow(name: row, state: at < position ? .done : at == position ? .current : .pending)
    }
  }
}
