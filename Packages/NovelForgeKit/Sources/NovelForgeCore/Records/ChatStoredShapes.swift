import ShadowCore
import ShadowText

enum ChatPassageContextMember: String, CaseIterable, FieldName {
  case kind
  case chapter
  case draftId
  case revision
  case saveSeq
  case start
  case end
  case passageHash
  case quote
  case comment
  case firstParagraph
  case lastParagraph
}

enum ChatQuestionMember: String, CaseIterable, FieldName {
  case question
  case why
  case answers
  case progressKey
}

enum ChatQuestionAnswerMember: String, CaseIterable, FieldName {
  case title
  case why
  case tradeOff
  case recommended
}

private let passageKind = "passage"

// apps/novel-forge-server/src/database/schemas/refinement.ts:134
extension ChatPassageContext: JSONRepresentable {
  init?(json: JSONValue) {
    guard let reader = FieldReader<ChatPassageContextMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      let kind: String = try reader.required(.kind)
      guard kind.utf8.elementsEqual(passageKind.utf8) else { return nil }
      self.init(
        chapter: try reader.required(.chapter), draftId: try reader.required(.draftId), revision: try reader.required(.revision), saveSeq: try reader.required(.saveSeq),
        start: try reader.required(.start), end: try reader.required(.end), passageHash: try reader.required(.passageHash), quote: try reader.required(.quote),
        comment: try reader.required(.comment), firstParagraph: try reader.required(.firstParagraph), lastParagraph: try reader.required(.lastParagraph))
    } catch {
      return nil
    }
  }

  var json: JSONValue {
    var fields = RecordFields<ChatPassageContextMember>()
    fields.put(.kind, passageKind)
    fields.put(.chapter, chapter)
    fields.put(.draftId, draftId)
    fields.put(.revision, revision)
    fields.put(.saveSeq, saveSeq)
    fields.put(.start, start)
    fields.put(.end, end)
    fields.put(.passageHash, passageHash)
    fields.put(.quote, quote)
    fields.put(.comment, comment)
    fields.put(.firstParagraph, firstParagraph)
    fields.put(.lastParagraph, lastParagraph)
    return fields.json
  }
}

// apps/novel-forge-server/src/modules/refinement/chat.dto.ts:119
extension ChatQuestionAnswer {
  init?(stored: JSONValue) {
    guard let reader = FieldReader<ChatQuestionAnswerMember>(object: stored) else { return nil }
    do throws(UnreadableReason) {
      let recommended: Bool? = try reader.optional(.recommended)
      self.init(title: try reader.required(.title), why: try reader.optional(.why), tradeOff: try reader.optional(.tradeOff), recommended: recommended ?? false)
    } catch {
      return nil
    }
  }

  var stored: JSONValue {
    var fields = RecordFields<ChatQuestionAnswerMember>()
    fields.put(.title, title)
    if let why { fields.put(.why, why) }
    if let tradeOff { fields.put(.tradeOff, tradeOff) }
    if recommended { fields.put(.recommended, true) }
    return fields.json
  }
}

// apps/novel-forge-server/src/modules/refinement/chat.dto.ts:138-151
extension ChatQuestion {
  init?(stored: JSONValue) {
    guard let reader = FieldReader<ChatQuestionMember>(object: stored) else { return nil }
    do throws(UnreadableReason) {
      let items: [JSONValue] = try reader.required(.answers)
      let answers = items.compactMap { ChatQuestionAnswer(stored: $0) }
      guard answers.count == items.count else { return nil }
      self.init(question: try reader.required(.question), why: try reader.optional(.why), answers: answers, progressKey: try reader.optional(.progressKey))
    } catch {
      return nil
    }
  }

  var stored: JSONValue {
    var fields = RecordFields<ChatQuestionMember>()
    fields.put(.question, question)
    if let why { fields.put(.why, why) }
    fields.put(.answers, JSONValue.array(answers.map(\.stored)))
    if let progressKey { fields.put(.progressKey, progressKey) }
    return fields.json
  }

  // apps/novel-forge-server/src/modules/refinement/chat-question.ts:19-20 and :54
  var isCard: Bool {
    !question.jsTrim().isEmpty && (2...4).contains(answers.count) && answers.allSatisfy { !$0.title.jsTrim().isEmpty }
  }
}
