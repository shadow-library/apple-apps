import ShadowCore
import ShadowText

/// A whole-draft write: a change set's `draft.update`, or the restore an inverse carries (draft.handler.ts:15, `DraftRestoreOp`), whose `null` title or
/// summary clears the field and whose containment brings an isolated draft back isolated.
struct DraftWrite: Sendable, Equatable {
  let chapter: Int
  var title: OpValue<String> = .omitted
  var body: String?
  var summary: OpValue<String> = .omitted
  var isolated: Bool?
  var generator: StoredEnum<ContentGenerator>?

  init(chapter: Int, title: OpValue<String> = .omitted, body: String? = nil, summary: OpValue<String> = .omitted) {
    self.chapter = chapter
    self.title = title
    self.body = body
    self.summary = summary
  }

  init(_ update: DraftUpdate) {
    self.init(chapter: update.chapter, title: update.title.map(OpValue.set) ?? .omitted, body: update.body, summary: update.summary.map(OpValue.set) ?? .omitted)
  }

  // draft.handler.ts:17
  init(restoring content: DraftContent, chapter: Int) {
    self.init(chapter: chapter, title: content.title.map(OpValue.set) ?? .null, body: content.body, summary: content.summary.map(OpValue.set) ?? .null)
    isolated = content.isolated
    generator = content.generator
  }

  var inverse: OrderedJSONObject {
    var encoder = OpEncoder()
    encoder.string("op", OpType.draftUpdate.rawValue)
    encoder.int("chapter", chapter)
    encoder.patchString("title", title)
    encoder.string("body", body)
    encoder.patchString("summary", summary)
    encoder.bool("isolated", isolated)
    encoder.string("generator", generator?.rawValue)
    return OrderedJSONObject(encoder.pairs)
  }
}

/// What undoes a draft change: the draft written back as it was, or its removal when the change created it.
enum DraftInverse: Sendable, Equatable {
  case restore(DraftWrite)
  case remove(chapter: Int)

  // draft.handler.ts:32
  static func removal(chapter: Int) -> OrderedJSONObject {
    var encoder = OpEncoder()
    encoder.string("op", OpType.draftRemove.rawValue)
    encoder.int("chapter", chapter)
    return OrderedJSONObject(encoder.pairs)
  }

  init(_ inverse: OrderedJSONObject) throws(ApplyRefusal) {
    let fields = OpFields(record: inverse)
    guard let chapter = fields.int("chapter"), chapter >= 1 else { throw .malformedInverse }
    switch fields.string("op").flatMap({ OpType(exactly: $0) }) {
    case .draftRemove?:
      self = .remove(chapter: chapter)
    case .draftUpdate?:
      guard let body = fields.string("body") else { throw .malformedInverse }
      var write = DraftWrite(chapter: chapter, title: fields.patchString("title"), body: body, summary: fields.patchString("summary"))
      write.isolated = fields.bool("isolated")
      write.generator = fields.string("generator").map(StoredEnum.init(rawValue:))
      self = .restore(write)
    default:
      throw .malformedInverse
    }
  }
}

extension OpValue {
  // apps/novel-forge-server/src/modules/refinement/apply/apply-rules.ts:8 (keptOr)
  func kept(or existing: Value?) -> Value? {
    switch self {
    case .omitted: existing
    case .null: nil
    case .set(let value): value
    }
  }
}
