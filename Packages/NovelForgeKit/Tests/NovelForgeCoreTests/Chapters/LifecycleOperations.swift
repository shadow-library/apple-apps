import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Synchronization

@testable import NovelForgeCore

/// Random drafts, approvals, judge reviews of a head (current or not, generation passes or not, findings of every kind), remedies of their findings and
/// generate jobs, with an unreadable review and purges: what the chapter lifecycle reads beyond the chapter writes.
enum LifecycleOperations {
  private static let severities: [StoredEnum<ReviewFindingSeverity>] = [
    .known(.blocking), .known(.blocking), .known(.warning), .known(.note), StoredEnum(rawValue: "severe"),
  ]
  private static let categories: [StoredEnum<ReviewFindingCategory>] = ReviewFindingCategory.allCases.map(StoredEnum.known) + [StoredEnum(rawValue: "tone")]
  private static let actions: [ReviewRemedyAction?] = [.dismissed, .fixingMyself, .overridden, nil]
  private static let seen = Mutex<Set<DraftReviewState>>([])

  private static let answered = Mutex(0)

  /// The statuses the operations found reconciled when they ran, for a property to gate on.
  static var reached: Set<DraftReviewState> { seen.withLock { $0 } }

  /// How many answers went to the review holding its chapter as a contradiction.
  static var answersToAHold: Int { answered.withLock { $0 } }

  /// Clears the gates; the operations are shared, so one property runs at a time.
  static func resetGates() {
    seen.withLock { $0 = [] }
    answered.withLock { $0 = 0 }
  }

  private static func observe(_ novel: UUID, in transaction: borrowing WriteTransaction) throws {
    let found = try ChapterLifecycleDerivation.request(for: novel).fetchAll(transaction.database).compactMap(\.review)
    seen.withLock { $0.formUnion(found) }
  }

  static func findings(_ generator: inout SeededGenerator) -> [ReviewFinding] {
    (0..<generator.int(in: generator.chance(0.8) ? 1...2 : 0...0)).map { index in
      ReviewFinding(
        id: "f\(index + 1)", severity: generator.pick(from: severities), category: generator.pick(from: categories), text: "Finding.", fingerprint: "fp\(index)")
    }
  }

  /// Oldest first, so the last is the one the lifecycle judges by.
  private static func reviews(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws -> [ChapterReviewRecord] {
    try ChapterReviewRecord.listing(novel: novel, chapter: chapter, in: transaction).entries.sorted { ($0.clock, $0.record.ref) < ($1.clock, $1.record.ref) }.map(\.record)
  }

  private static func jobs(novel: UUID, chapter: Int) -> [JobKey] {
    (1...2).compactMap { run in try? ReviewWrites.generateKey(novel: novel, chapter: chapter, run: run) }
  }

  static let all: [ProjectionOperation] = [
    ProjectionOperation(name: "save a draft recording its upstream", weight: 4) { generator, universe in
      let (novel, chapter, body) = (universe.novel(&generator), universe.chapter(&generator), universe.text(&generator))
      return { transaction in
        try observe(novel, in: transaction)
        try ChapterWrites.draft(novel: novel, chapter: chapter, body: body, in: &transaction)
      }
    },
    ProjectionOperation(name: "approve a draft head", weight: 6) { generator, universe in
      let (novel, chapter, id) = (universe.novel(&generator), universe.chapter(&generator), generator.uuid())
      return { transaction in
        try observe(novel, in: transaction)
        try ChapterWrites.approve(novel: novel, chapter: chapter, id: id, in: &transaction)
      }
    },
    ProjectionOperation(name: "append a judge review", weight: 5) { generator, universe in
      let (novel, chapter, findings) = (universe.novel(&generator), universe.chapter(&generator), findings(&generator))
      let (verdict, pass, stale, id) = (
        generator.pick(from: ["consistent", "contradiction", "evaluation_failed"]), generator.chance(0.5), generator.chance(0.15), generator.uuid()
      )
      return { transaction in
        try observe(novel, in: transaction)
        guard try ChapterWrites.head(novel: novel, chapter: chapter, in: transaction) != nil else { return }
        try ReviewWrites.judge(
          novel: novel, chapter: chapter, findings: findings, verdict: verdict, generationPass: pass, body: stale ? "Other text." : nil, id: id, in: &transaction)
      }
    },
    ProjectionOperation(name: "append an unreadable judge review", weight: 1) { generator, universe in
      let (novel, chapter, id) = (universe.novel(&generator), universe.chapter(&generator), generator.uuid())
      return { transaction in
        try observe(novel, in: transaction)
        let review = try ChapterReviewRecord(
          id: id, novel: novel, chapter: chapter, reviewKind: .known(.judge), draftRevision: nil, bodyHash: "h", disposition: .known(.blocking))
        var item = review.item
        item[ChapterReviewMember.findings.rawValue] = .array([.null])
        _ = try transaction.append(review.ref, item: item)
      }
    },
    ProjectionOperation(name: "answer a judge finding", weight: 8) { generator, universe in
      let (novel, any, aimed, pick, finding, action) = (
        universe.novel(&generator), universe.chapter(&generator), generator.chance(0.7), generator.chance(0.8) ? nil : generator.int(in: 0...9),
        generator.pick(from: ["f1", "f2"]), generator.pick(from: actions)
      )
      return { transaction in
        try observe(novel, in: transaction)
        let held = try ChapterLifecycleDerivation.request(for: novel).fetchAll(transaction.database).filter { $0.review == .contradiction }.map(\.chapter)
        let chapter = aimed && !held.isEmpty ? held[any % held.count] : any
        let reviews = try reviews(novel: novel, chapter: chapter, in: transaction)
        guard let latest = reviews.last else { return }
        let review = pick.map { reviews[$0 % reviews.count] } ?? latest
        let entry = try ChapterLifecycleEntry.read(novel: novel, chapter: chapter, in: transaction.database)
        if entry?.review == .contradiction, entry?.judge == review.id { answered.withLock { $0 += 1 } }
        try ReviewWrites.remedy(novel: novel, review: review.id, finding: finding, action, in: &transaction)
      }
    },
    ProjectionOperation(name: "purge a judge review", weight: 1) { generator, universe in
      let (novel, chapter, pick) = (universe.novel(&generator), universe.chapter(&generator), generator.int(in: 0...9))
      return { transaction in
        try observe(novel, in: transaction)
        let reviews = try reviews(novel: novel, chapter: chapter, in: transaction)
        guard !reviews.isEmpty else { return }
        _ = try transaction.purge(reviews[pick % reviews.count].ref)
      }
    },
    ProjectionOperation(name: "request a generate job", weight: 2) { generator, universe in
      let (novel, chapter, run) = (universe.novel(&generator), universe.chapter(&generator), generator.int(in: 1...2))
      return { transaction in
        try observe(novel, in: transaction)
        try ReviewWrites.requestGeneration(novel: novel, chapter: chapter, run: run, in: &transaction)
      }
    },
    ProjectionOperation(name: "cancel a generate job", weight: 2) { generator, universe in
      let key = generator.pick(from: jobs(novel: universe.novel(&generator), chapter: universe.chapter(&generator)))
      return { transaction in
        guard try transaction.state(of: key.ref) != nil else { return }
        try ReviewWrites.cancel(key.ref, in: &transaction)
      }
    },
    ProjectionOperation(name: "finish a generate job", weight: 3) { generator, universe in
      let key = generator.pick(from: jobs(novel: universe.novel(&generator), chapter: universe.chapter(&generator)))
      let attempt = try? JobWorld.attemptID(at: Int64(generator.int(in: 0...900)), &generator)
      return { transaction in
        guard let attempt, try transaction.state(of: key.ref) != nil, try transaction.state(of: attempt.ref) == nil else { return }
        try ReviewWrites.succeed(key.ref, attempt: attempt, in: &transaction)
      }
    },
  ]
}
