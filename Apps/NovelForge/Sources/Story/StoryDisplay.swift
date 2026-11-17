import Foundation
import NovelForgeCore
import ShadowCore

nonisolated enum PromiseStanding: Equatable {
  case open
  case settled
  case dropped
  case unrecognised
}

nonisolated enum PromiseChapterMark: Equatable {
  case settled(Int)
  case opened(Int)
}

nonisolated extension VolumeItem {
  var displayName: String { record.title?.storyNonBlank ?? record.volume }
  var hasTitle: Bool { record.title?.storyNonBlank != nil }
}

nonisolated extension StoryPromise {
  var ref: PromiseRef {
    switch self {
    case .thread(let record): .thread(record.thread)
    case .mystery(let record): .mystery(record.mystery)
    }
  }

  var label: String {
    switch self {
    case .thread(let record): record.summary?.storyNonBlank ?? record.thread
    case .mystery(let record): record.question.storyNonBlank ?? record.mystery
    }
  }

  var openedChapter: Int? {
    switch self {
    case .thread(let record): record.openedChapter
    case .mystery(let record): record.openedChapter
    }
  }

  var settledChapter: Int? {
    switch self {
    case .thread(let record): record.status.chapter
    case .mystery(let record): record.status.chapter
    }
  }

  var standing: PromiseStanding {
    switch self {
    case .thread(let record):
      switch record.status.state {
      case .known(.open): .open
      case .known(.closed): .settled
      case .known(.dropped): .dropped
      case .unknown: .unrecognised
      }
    case .mystery(let record):
      switch record.status.state {
      case .known(.open): .open
      case .known(.resolved): .settled
      case .known(.dropped): .dropped
      case .unknown: .unrecognised
      }
    }
  }

  var chapterMark: PromiseChapterMark? {
    if standing == .settled, let chapter = settledChapter, chapter > 0 { return .settled(chapter) }
    guard let chapter = openedChapter, chapter > 0 else { return nil }
    return .opened(chapter)
  }

  var isDormant: Bool {
    switch self {
    case .thread(let record): record.dormant
    case .mystery(let record): record.dormant
    }
  }
}

nonisolated extension PromiseRef {
  var kindName: String {
    switch self {
    case .thread: "thread"
    case .mystery: "mystery"
    }
  }
}

nonisolated extension StoryStructure {
  func volume(_ key: String) -> VolumeItem? {
    volumes.value?.items.first { $0.record.volume == key }
  }

  func milestone(_ key: String) -> MilestoneItem? {
    milestones.value?.items.first { $0.record.milestone == key }
  }

  func promise(_ ref: PromiseRef) -> StoryPromise? {
    promises.value?.items.first { $0.ref == ref }
  }

  func secret(_ key: String) -> SecretRecord? {
    secrets.value?.items.first { $0.secret == key }
  }
}

nonisolated enum UnlockTerm: Hashable {
  case milestone(String)
  case volume(String)
  case chapter(Int)
  case ending

  var json: JSONValue {
    switch self {
    case .milestone(let key): .object(["milestone": .string(key)])
    case .volume(let key): .object(["volume": .string(key)])
    case .chapter(let number): .object(["chapter": .int(Int64(number))])
    case .ending: .object(["ending": .bool(true)])
    }
  }

  static func condition(_ terms: [UnlockTerm]) -> JSONValue? {
    terms.isEmpty ? nil : .object(["all": .array(terms.map(\.json))])
  }

  static func parse(_ unlock: JSONValue?) -> [UnlockTerm]? {
    guard let unlock else { return [] }
    guard case .object(let object) = unlock, object.count == 1, case .array(let items)? = object["all"] else { return nil }
    var terms = [UnlockTerm]()
    for item in items {
      guard case .object(let fields) = item, fields.count == 1, let (name, value) = fields.first else { return nil }
      switch (name, value) {
      case ("milestone", .string(let key)): terms.append(.milestone(key))
      case ("volume", .string(let key)): terms.append(.volume(key))
      case ("chapter", .int(let number)): terms.append(.chapter(Int(number)))
      case ("ending", .bool(true)): terms.append(.ending)
      default: return nil
      }
    }
    return terms
  }
}

nonisolated enum UnlockChange: Equatable {
  case keep
  case replace([UnlockTerm])
}
