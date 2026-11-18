import ShadowAI

enum ChapterRole: String, CaseIterable, Sendable {
  case draft
  case title
  case judge
  case repair
  case revise
  case review
  case summary
  case continuity
  case extraction
}

extension ChapterRole {
  // apps/novel-forge-server/src/modules/ai/chapter-route.ts:17
  var aiRole: String {
    switch self {
    case .draft: "generation"
    case .title: "title"
    case .judge: "judge"
    case .repair: "fix"
    case .revise: "revision"
    case .review: "review"
    case .summary, .continuity: "continuity"
    case .extraction: "extraction"
    }
  }

  // apps/novel-forge-server/src/modules/ai/defaults.ts:40
  var modelTask: ModelTask {
    switch self {
    case .draft, .repair, .revise: .writing
    case .title: .helper
    case .judge, .review, .summary, .continuity: .review
    case .extraction: .planning
    }
  }

  var outputScope: HardLineScope { NovelForgeCore.outputScope(role: aiRole) }
}

struct ChapterModeSource: Equatable, Sendable {
  var planMode: ModelContentMode?
  var isolated: Bool

  init(planMode: ModelContentMode? = nil, isolated: Bool = false) {
    self.planMode = planMode
    self.isolated = isolated
  }
}

// apps/novel-forge-server/src/modules/ai/chapter-route.ts:37
func chapterContentMode(_ source: ChapterModeSource) -> ModelContentMode {
  if source.isolated { return .unrestricted }
  return source.planMode ?? .standard
}

enum ChapterContainment: Equatable, Sendable {
  case isolatedUnrestricted
}

// apps/novel-forge-server/src/modules/ai/chapter-route.ts:47
func chapterContainment(mode: ModelContentMode, raised: Bool) -> ChapterContainment? {
  mode == .unrestricted || raised ? .isolatedUnrestricted : nil
}
