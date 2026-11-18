import Foundation

struct EditorialReviewOutput: Decodable, Equatable, Sendable {
  enum Disposition: String, Decodable, Equatable, Sendable {
    case approve
    case revisionRequested = "revision_requested"
  }

  enum Severity: String, Decodable, Equatable, Sendable {
    case blocking
    case suggestion
  }

  enum SlipKind: String, Decodable, CaseIterable, Equatable, Sendable {
    case grammar
    case spelling
    case punctuation
    case tense
    case pov
    case name
    case reference
  }

  struct Finding: Decodable, Equatable, Sendable {
    var severity: Severity
    var text: String
    var evidence: String?
  }

  struct Slip: Decodable, Equatable, Sendable {
    var kind: SlipKind
    var quote: String
    var fix: String
    var reason: String?
  }

  var disposition: Disposition
  var note: String?
  var findings: [Finding]?
  var proofreading: [Slip]?

  init(data: Data) throws {
    self = try JSONDecoder().decode(Self.self, from: data)
  }
}
