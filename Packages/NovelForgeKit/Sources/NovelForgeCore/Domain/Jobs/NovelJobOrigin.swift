import Foundation
import ShadowCore

enum NovelJobOrigin {
  static func json(session: UUID, message: UUID?, proposal: UUID, opIndex: Int) -> JSONValue {
    [
      NovelJobOriginMember.session.rawValue: .string(session.lowercasedString), NovelJobOriginMember.message.rawValue: message.map { .string($0.lowercasedString) } ?? .null,
      NovelJobOriginMember.proposal.rawValue: .string(proposal.lowercasedString), NovelJobOriginMember.opIndex.rawValue: .int(Int64(opIndex)),
    ]
  }
}
