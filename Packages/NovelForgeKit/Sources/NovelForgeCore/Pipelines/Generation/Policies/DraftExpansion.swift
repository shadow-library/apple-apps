struct DraftExpansionRequest: Equatable, Sendable {
  let pass: Int
  let draftBody: String
  let draftWords: Int
  let minWords: Double
  let aimWords: Double
  let missingWords: Double
}

struct DraftExpansionState: Equatable, Sendable {
  let body: String
  let words: Int
  let passes: Int
  let initialWords: Int
  let stopped: Bool
}

struct DraftExpansionResult: Equatable, Sendable {
  let body: String
  let passes: Int
  let initialWords: Int
  let finalWords: Int
}

enum DraftExpansion {
  // apps/novel-forge-server/src/modules/ai/graphs/draft-expansion.ts:13
  static let maxPasses = 2

  // apps/novel-forge-server/src/modules/ai/graphs/draft-expansion.ts:42
  static func begin(body: String) -> DraftExpansionState {
    let words = ProseMetrics.countProseWords(body)
    return DraftExpansionState(body: body, words: words, passes: 0, initialWords: words, stopped: false)
  }

  // apps/novel-forge-server/src/modules/ai/graphs/draft-expansion.ts:47
  static func nextRequest(_ state: DraftExpansionState, target: ResolvedWordTarget, maxPasses: Int = maxPasses) -> DraftExpansionRequest? {
    guard !state.stopped, Double(state.words) < target.min, state.passes < maxPasses else { return nil }
    return DraftExpansionRequest(
      pass: state.passes + 1, draftBody: state.body, draftWords: state.words, minWords: target.min, aimWords: target.aim, missingWords: target.aim - Double(state.words))
  }

  // apps/novel-forge-server/src/modules/ai/graphs/draft-expansion.ts:58
  static func settle(_ state: DraftExpansionState, expandedBody: String?, target: ResolvedWordTarget) -> DraftExpansionState {
    let passes = state.passes + 1
    guard let expandedBody else { return state.stopping(passes: passes) }
    let expandedWords = ProseMetrics.countProseWords(expandedBody)
    guard expandedWords > state.words, Double(expandedWords) <= MechanicalCheck.resolveWordCountHardBounds(target).max else { return state.stopping(passes: passes) }
    return DraftExpansionState(body: expandedBody, words: expandedWords, passes: passes, initialWords: state.initialWords, stopped: false)
  }

  static func result(_ state: DraftExpansionState) -> DraftExpansionResult {
    DraftExpansionResult(body: state.body, passes: state.passes, initialWords: state.initialWords, finalWords: state.words)
  }

  static func run(
    body: String, target: ResolvedWordTarget, maxPasses: Int = maxPasses, expand: (DraftExpansionRequest) async -> String?
  ) async -> DraftExpansionResult {
    var state = begin(body: body)
    while let request = nextRequest(state, target: target, maxPasses: maxPasses) {
      state = settle(state, expandedBody: await expand(request), target: target)
    }
    return result(state)
  }
}

extension DraftExpansionState {
  fileprivate func stopping(passes: Int) -> DraftExpansionState {
    DraftExpansionState(body: body, words: words, passes: passes, initialWords: initialWords, stopped: true)
  }
}
