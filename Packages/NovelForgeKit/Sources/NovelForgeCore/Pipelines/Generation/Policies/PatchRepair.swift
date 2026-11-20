import ShadowText

enum RepairMode: String, CaseIterable, Sendable {
  case patch
  case rewrite
}

struct ProsePatch: Equatable, Sendable {
  let find: String
  let replace: String
}

struct RepairProposal: Equatable, Sendable {
  var action: RepairMode
  var body: String?
  var patches: [ProsePatch]?
}

enum PatchRejection: Error, Equatable, Sendable {
  case emptyAnchor(patch: Int)
  case anchorNotFound(patch: Int)
  case anchorAmbiguous(patch: Int, occurrences: Int)
}

enum PatchRepairOutcome: Equatable, Sendable {
  case rewriteBody(String)
  case patched(String)
  case fallBackToRewrite(PatchRejection?)
}

enum PatchRepair {
  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:770
  static func resolve(_ proposal: RepairProposal, prose: String) -> PatchRepairOutcome {
    if proposal.action == .rewrite, let body = proposal.body, !body.isEmpty { return .rewriteBody(body) }
    guard proposal.action == .patch, let patches = proposal.patches, !patches.isEmpty else { return .fallBackToRewrite(nil) }
    do {
      return .patched(try apply(patches, to: prose))
    } catch {
      return .fallBackToRewrite(error)
    }
  }

  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:778
  static func apply(_ patches: [ProsePatch], to prose: String) throws(PatchRejection) -> String {
    var patched = prose
    for (index, patch) in patches.enumerated() {
      guard !patch.find.isEmpty else { throw .emptyAnchor(patch: index) }
      let occurrences = patched.jsSplit(patch.find).count - 1
      guard occurrences == 1 else { throw occurrences == 0 ? .anchorNotFound(patch: index) : .anchorAmbiguous(patch: index, occurrences: occurrences) }
      let start = patched.jsIndexOf(patch.find)
      patched = patched.jsSlice(0, start) + patch.replace + patched.jsSlice(start + patch.find.jsLength)
    }
    return patched
  }
}

enum RevisionSource {
  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:131
  static func named(attempt: Int, repairMode: RepairMode) -> DraftSource {
    if attempt == 0 { return .generated }
    return repairMode == .patch ? .patched : .rewritten
  }
}
