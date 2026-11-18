import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport

@testable import NovelForgeCore

/// What the generation and review pipelines will write about a chapter, as records: generate jobs requested, cancelled or finished; judge reviews of a head,
/// generation passes or not, current or of other text; remedies of their findings. Only requests, cancels and successful attempts are written, so a job is open
/// exactly while it is neither cancelled nor succeeded.
enum DomainReviewOperations {
  private static let severities: [ReviewFindingSeverity] = [.blocking, .blocking, .warning, .note]
  private static let categories: [ReviewFindingCategory] = [.continuity, .continuity, .brief, .readability, .mechanics, .knowledge]
  private static let actions: [ReviewRemedyAction?] = [.dismissed, .overridden, .fixingMyself, nil]

  private static func findings(_ generator: inout SeededGenerator) -> [ReviewFinding] {
    (0..<generator.int(in: 0...2)).map { index in
      ReviewWrites.finding("f\(index + 1)", generator.pick(from: severities), generator.pick(from: categories))
    }
  }

  static let all: [DomainOperation] = [
    DomainOperation(name: "request a generate job", weight: 2) { generator, universe in
      let (novel, aim, run) = (universe.primary, ChapterAim(.drafted, &generator, universe), generator.int(in: 1...2))
      return .write { transaction, _ in
        _ = try ReviewWrites.requestGeneration(novel: novel, chapter: try aim.chapter(novel: novel, in: transaction.database), run: run, in: &transaction)
      }
    },
    DomainOperation(name: "cancel or finish a generate job", weight: 3) { generator, universe in
      let (novel, pick, finishes) = (universe.primary, generator.int(in: 0...7), generator.chance(0.6))
      let attempt = try? JobWorld.attemptID(at: Int64(generator.int(in: 0...900)), &generator)
      return .write { transaction, _ in
        let open = try JobActivityRow.filter(Column("novel") == novel).fetchAll(transaction.database).map(\.ref).sorted()
        guard !open.isEmpty else { return }
        let job = open[pick % open.count]
        guard finishes, let attempt else { return try ReviewWrites.cancel(job, in: &transaction) }
        try ReviewWrites.succeed(job, attempt: attempt, in: &transaction)
      }
    },
    DomainOperation(name: "record a judge review of a draft", weight: 4) { generator, universe in
      let (novel, aim, findings) = (universe.primary, ChapterAim(.drafted, &generator, universe), findings(&generator))
      let (verdict, pass, current, id) = (
        generator.pick(from: ["consistent", "contradiction", "evaluation_failed"]), generator.chance(0.5), generator.chance(0.85), generator.uuid()
      )
      return .write { transaction, _ in
        let chapter = try aim.chapter(novel: novel, in: transaction.database)
        guard try ChapterWrites.head(novel: novel, chapter: chapter, in: transaction) != nil else { return }
        try ReviewWrites.judge(
          novel: novel, chapter: chapter, findings: findings, verdict: verdict, generationPass: pass, body: current ? nil : "Other text.", id: id, in: &transaction)
      }
    },
    DomainOperation(name: "answer a review finding", weight: 3) { generator, universe in
      let (novel, aim, finding, action) = (universe.primary, ChapterAim(.drafted, &generator, universe), generator.pick(from: ["f1", "f2"]), generator.pick(from: actions))
      return .write { transaction, _ in
        let chapter = try aim.chapter(novel: novel, in: transaction.database)
        let reviews = try ChapterReviewRecord.listing(novel: novel, chapter: chapter, in: transaction).entries.sorted { ($0.clock, $0.record.ref) < ($1.clock, $1.record.ref) }
        guard let latest = reviews.last else { return }
        try ReviewWrites.remedy(novel: novel, review: latest.record.id, finding: finding, action, in: &transaction)
      }
    },
  ]
}
