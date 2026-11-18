import Foundation

public enum Manuscript {
  /// apps/novel-forge-server/src/modules/generation/generation.service.ts:1002-1010: `# title` (or `# Chapter N`), a blank line and the body, chapters joined by `---`.
  public static func markdown(of chapters: [ExportChapter]) -> String {
    chapters.sorted { $0.number < $1.number }.map { "# \($0.title ?? "Chapter \($0.number)")\n\n\($0.content)" }.joined(separator: "\n\n---\n\n")
  }
}
