import Foundation

public struct ExportChapter: Sendable, Equatable {
  public let number: Int
  public let title: String?
  public let content: String

  public init(number: Int, title: String?, content: String) {
    self.number = number
    self.title = title
    self.content = content
  }
}

public struct ExportNovel: Sendable, Equatable {
  public let id: UUID
  public let name: String
  public let title: String?
  public let brief: String?
  public let premise: String?
  public let themes: [String]?

  public init(id: UUID, name: String, title: String? = nil, brief: String? = nil, premise: String? = nil, themes: [String]? = nil) {
    self.id = id
    self.name = name
    self.title = title
    self.brief = brief
    self.premise = premise
    self.themes = themes
  }
}
