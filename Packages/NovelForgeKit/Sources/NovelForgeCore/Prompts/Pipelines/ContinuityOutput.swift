import Foundation

struct ContinuityOutput: Decodable, Equatable, Sendable {
  struct Milestone: Decodable, Equatable, Sendable {
    var milestoneKey: String
    var reached: Bool
    var evidence: String?
  }

  struct NewEntity: Decodable, Equatable, Sendable {
    var entityKey: String
    var name: String
    var type: EntityType
    var notes: String?
  }

  struct Thread: Decodable, Equatable, Sendable {
    var threadKey: String
    var status: ThreadStatus
    var summary: String?
    var intentionallyOpen: Bool?
    var confidence: Confidence?
  }

  struct Mystery: Decodable, Equatable, Sendable {
    var mysteryKey: String
    var status: MysteryStatus
    var question: String?
    var intentionallyOpen: Bool?
    var truthFactKey: String?
    var confidence: Confidence?
  }

  struct TimelineEvent: Decodable, Equatable, Sendable {
    var whenText: String?
    var event: String
    var significance: String?
  }

  struct Relationship: Decodable, Equatable, Sendable {
    var entityKey: String
    var targetKey: String
    var kind: String
    var note: String?
    var evidence: String
    var confidence: Confidence?
  }

  struct Power: Decodable, Equatable, Sendable {
    var character: String
    var stage: String
    var feat: String?
    var next: String?
  }

  struct CharacterState: Decodable, Equatable, Sendable {
    var entityKey: String
    var location: String?
    var conditions: [String]?
    var immediateGoal: String?
    var statusNote: String?
    var evidence: String
    var confidence: Confidence?
  }

  struct KnowledgeChange: Decodable, Equatable, Sendable {
    var entityKey: String
    var factKey: String
    var how: String
  }

  enum Confidence: String, Decodable, Equatable, Sendable {
    case high
    case low
  }

  var milestones: [Milestone]?
  var appeared: [String]
  var newEntities: [NewEntity]
  var threads: [Thread]
  var mysteries: [Mystery]
  var timeline: [TimelineEvent]
  var relationships: [Relationship]
  var power: [Power]
  var characterStates: [CharacterState]
  var knowledgeChanges: [KnowledgeChange]
  var chapterSummary: String

  init(data: Data) throws {
    self = try JSONDecoder().decode(Self.self, from: data)
  }

  var finalizeExtraction: FinalizeExtraction {
    func assessed<Value: Sendable>(_ value: Value, _ confidence: Confidence?) -> FinalizeExtraction.Assessed<Value> {
      FinalizeExtraction.Assessed(value, confidence: confidence.flatMap { FinalizeExtraction.Confidence(rawValue: $0.rawValue) })
    }
    return FinalizeExtraction(
      appeared: appeared,
      newEntities: newEntities.map { ProposedChange.Entity(entityKey: $0.entityKey, name: $0.name, type: $0.type, notes: $0.notes) },
      threads: threads.map {
        assessed(ProposedChange.PlotThread(threadKey: $0.threadKey, status: $0.status, summary: $0.summary, intentionallyOpen: $0.intentionallyOpen), $0.confidence)
      },
      mysteries: mysteries.map {
        assessed(
          ProposedChange.Mystery(mysteryKey: $0.mysteryKey, status: $0.status, question: $0.question, intentionallyOpen: $0.intentionallyOpen, truthFactKey: $0.truthFactKey),
          $0.confidence)
      },
      relationships: relationships.map {
        assessed(ProposedChange.Relationship(entityKey: $0.entityKey, targetKey: $0.targetKey, kind: $0.kind, note: $0.note, evidence: $0.evidence), $0.confidence)
      },
      characterStates: characterStates.map {
        assessed(
          ProposedChange.CharacterState(
            entityKey: $0.entityKey, location: $0.location, conditions: $0.conditions, immediateGoal: $0.immediateGoal, statusNote: $0.statusNote, evidence: $0.evidence),
          $0.confidence)
      },
      knowledgeChanges: knowledgeChanges.map { ProposedChange.Knowledge(entityKey: $0.entityKey, factKey: $0.factKey, how: $0.how) },
      chapterSummary: chapterSummary,
      milestones: (milestones ?? []).map { FinalizeExtraction.Milestone(milestoneKey: $0.milestoneKey, reached: $0.reached, evidence: $0.evidence) })
  }
}
