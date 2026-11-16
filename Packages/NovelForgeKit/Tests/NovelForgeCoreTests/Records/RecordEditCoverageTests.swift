import Foundation
import ShadowCore
import Testing

@testable import NovelForgeCore

private func expectOnlyTheNamedField<Field: FieldName>(_ field: Field, _ fields: RecordFields<Field>) {
  #expect(Set(fields.members.keys) == [field.rawValue], "\(field.rawValue)")
}

@Suite("Edit types cover every field", .timeLimit(.minutes(1)))
struct RecordEditCoverageTests {
  @Test func shouldLetANovelEditSetEveryNovelFieldAndNothingElse() {
    for field in NovelField.allCases {
      var edit = NovelEdit()
      switch field {
      case .name: edit.name = .set("n")
      case .title: edit.title = .set(nil)
      case .contentMode: edit.contentMode = .set(.known(.standard))
      case .costTier: edit.costTier = .set(.known(.balanced))
      case .wordTarget: edit.wordTarget = .set(WordTarget(min: 1, max: 2))
      case .brief: edit.brief = .set(nil)
      case .premise: edit.premise = .set(nil)
      case .themes: edit.themes = .set([])
      case .theme: edit.theme = .set(nil)
      case .endingQuestion: edit.endingQuestion = .set(nil)
      case .ending: edit.ending = .set(nil)
      case .readerPromise: edit.readerPromise = .set(nil)
      case .protagonist: edit.protagonist = .set(nil)
      case .opposition: edit.opposition = .set(nil)
      case .writingStyle: edit.writingStyle = .set(nil)
      case .archived: edit.archived = .set(true)
      }
      expectOnlyTheNamedField(field, edit.fields)
    }
  }

  @Test func shouldLetAVolumeEditSetEveryVolumeFieldAndNothingElse() {
    for field in VolumeField.allCases {
      var edit = VolumeEdit()
      switch field {
      case .ordinal: edit.ordinal = .set(1)
      case .title: edit.title = .set(nil)
      case .objective: edit.objective = .set(nil)
      case .body: edit.body = .set(nil)
      case .goalMet: edit.goalMet = .set(true)
      }
      expectOnlyTheNamedField(field, edit.fields)
    }
  }

  @Test func shouldLetAMilestoneEditSetEveryMilestoneFieldAndNothingElse() {
    for field in MilestoneField.allCases {
      var edit = MilestoneEdit()
      switch field {
      case .label: edit.label = .set("l")
      case .subject: edit.subject = .set(nil)
      case .kind: edit.kind = .set(.known(.rank))
      }
      expectOnlyTheNamedField(field, edit.fields)
    }
  }

  @Test func shouldLetAThreadEditSetEveryThreadFieldAndNothingElse() {
    for field in ThreadField.allCases {
      var edit = ThreadEdit()
      switch field {
      case .summary: edit.summary = .set(nil)
      case .openedChapter: edit.openedChapter = .set(nil)
      case .status: edit.status = .set(ThreadProgress(state: .known(.closed), chapter: 2))
      case .payoffWindow: edit.payoffWindow = .set(nil)
      case .payoffMilestone: edit.payoffMilestone = .set(nil)
      case .payoffVolume: edit.payoffVolume = .set(nil)
      case .dormant: edit.dormant = .set(true)
      }
      expectOnlyTheNamedField(field, edit.fields)
    }
  }

  @Test func shouldLetAMysteryEditSetEveryMysteryFieldAndNothingElse() {
    for field in MysteryField.allCases {
      var edit = MysteryEdit()
      switch field {
      case .question: edit.question = .set("q")
      case .openedChapter: edit.openedChapter = .set(nil)
      case .status: edit.status = .set(MysteryProgress(state: .known(.resolved), chapter: 2))
      case .truthFact: edit.truthFact = .set(nil)
      case .payoffWindow: edit.payoffWindow = .set(nil)
      case .payoffMilestone: edit.payoffMilestone = .set(nil)
      case .payoffVolume: edit.payoffVolume = .set(nil)
      case .dormant: edit.dormant = .set(true)
      }
      expectOnlyTheNamedField(field, edit.fields)
    }
  }
}
