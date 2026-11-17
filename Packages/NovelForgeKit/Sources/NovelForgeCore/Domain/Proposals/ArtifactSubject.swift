import Foundation
import ShadowCore
import ShadowStore

enum ArtifactSubject: Sendable {
  case premise(NovelRecord)
  case doc(PageRecord)
  case volume(VolumeRecord)
  case chapter(ChapterPlanRecord)
  case draft(DraftRecord)
  case entity(EntityRecord)
  case fact(SecretRecord)
  case milestone(MilestoneRecord)
  case thread(ThreadRecord)
  case mystery(MysteryRecord)
}

enum ArtifactReading: Sendable {
  case missing
  case present(ArtifactSubject)
  case unreadable
}

private func classify<Record: Sendable & Equatable>(_ reading: RecordReading<Record>, _ wrap: (Record) -> ArtifactSubject) -> ArtifactReading {
  switch reading {
  case .absent: .missing
  case .unreadable: .unreadable
  case .readable(let entry): entry.isRemoved ? .missing : .present(wrap(entry.record))
  }
}

extension ArtifactSubject {
  // An absent or removed record is a missing row, as the reference treats a row it cannot find; one this device cannot read is never missing
  static func read<Transaction: StateReading & ~Copyable>(_ ref: ArtifactRef, novel: UUID, in transaction: borrowing Transaction) throws(StoreError) -> ArtifactReading {
    switch ref {
    case .premise:
      return classify(try NovelRecord.read(id: novel, in: transaction), ArtifactSubject.premise)
    case .doc(let section, let slug):
      guard let known = BiblePageSection.allCases.first(where: { $0.rawValue.jsEquals(section) }) else { return .missing }
      return classify(try PageRecord.read(novel: novel, section: known, slug: slug, in: transaction), ArtifactSubject.doc)
    case .volume(let key):
      return classify(try VolumeRecord.read(novel: novel, volume: key, in: transaction), ArtifactSubject.volume)
    case .chapter(let chapter):
      guard let planRef = try? ChapterPlanRecord.ref(novel: novel, chapter: chapter) else { return .missing }
      return classify(try ChapterPlanRecord.read(planRef, in: transaction), ArtifactSubject.chapter)
    case .draft(let chapter):
      guard let draftRef = try? DraftRecord.ref(novel: novel, chapter: chapter) else { return .missing }
      return classify(try DraftRecord.read(draftRef, in: transaction), ArtifactSubject.draft)
    case .entity(let key):
      return classify(try EntityRecord.read(novel: novel, entity: key, in: transaction), ArtifactSubject.entity)
    case .fact(let key):
      return classify(try SecretRecord.read(novel: novel, secret: key, in: transaction), ArtifactSubject.fact)
    case .milestone(let key):
      return classify(try MilestoneRecord.read(novel: novel, milestone: key, in: transaction), ArtifactSubject.milestone)
    case .promise(.thread(let key)):
      return classify(try ThreadRecord.read(novel: novel, thread: key, in: transaction), ArtifactSubject.thread)
    case .promise(.mystery(let key)):
      return classify(try MysteryRecord.read(novel: novel, mystery: key, in: transaction), ArtifactSubject.mystery)
    }
  }
}
