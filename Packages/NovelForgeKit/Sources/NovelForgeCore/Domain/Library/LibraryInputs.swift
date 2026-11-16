import Foundation
import ShadowStore

public struct NewNovel: Sendable, Equatable {
  public var title: String
  public var notes: String?
  public var contentMode: ContentMode
  public var costTier: CostTier
  public var writingStyle: String?
  public var wordTarget: WordTarget?

  public init(
    title: String, notes: String? = nil, contentMode: ContentMode = .standard, costTier: CostTier = .balanced, writingStyle: String? = nil, wordTarget: WordTarget? = nil
  ) {
    self.title = title
    self.notes = notes
    self.contentMode = contentMode
    self.costTier = costTier
    self.writingStyle = writingStyle
    self.wordTarget = wordTarget
  }
}

public struct NovelChanges: Sendable, Equatable {
  public var title: FieldChange<String?> = .keep
  public var contentMode: FieldChange<StoredEnum<ContentMode>> = .keep
  public var costTier: FieldChange<StoredEnum<CostTier>> = .keep
  public var wordTarget: FieldChange<WordTarget?> = .keep
  public var brief: FieldChange<String?> = .keep
  public var theme: FieldChange<String?> = .keep
  public var endingQuestion: FieldChange<String?> = .keep
  public var ending: FieldChange<String?> = .keep
  public var readerPromise: FieldChange<String?> = .keep
  public var protagonist: FieldChange<String?> = .keep
  public var opposition: FieldChange<String?> = .keep
  public var writingStyle: FieldChange<String?> = .keep

  public init() {}

  var isEmpty: Bool { self == NovelChanges() }
}

public struct NovelCopy: Sendable, Equatable {
  public var name: String
  public var contentMode: ContentMode?
  public var wordTarget: WordTarget?

  public init(name: String, contentMode: ContentMode? = nil, wordTarget: WordTarget? = nil) {
    self.name = name
    self.contentMode = contentMode
    self.wordTarget = wordTarget
  }
}

public struct NovelList: Sendable, Equatable {
  public let novels: [NovelRecord]
  public let unreadable: Int
}
