import Foundation
import ShadowText

/// One stored event of a turn, as the reference's `TurnEventRecord` (apps/novel-forge-server/src/modules/refinement/turn-stream.types.ts:15): `data` is the
/// event's JSON text, and a reader at `sequence` n has seen every frame below it that was kept.
public struct TurnFrame: Sendable, Equatable {
  public let sequence: Int
  public let event: TurnStreamEventName
  public let data: String

  init(sequence: Int, event: TurnStreamEventName, data: String) {
    self.sequence = sequence
    self.event = event
    self.data = data
  }

  init(sequence: Int, _ event: TurnStreamEvent) {
    self.init(sequence: sequence, event: event.name, data: OrderedJSON.object(event.frameData).jsonText)
  }

  /// Nil when the data does not read as its event: a reader steps over such a frame as it steps over a gap. A reset carries nothing to read, and stepping
  /// over one would leave voided text on show.
  public var decoded: TurnStreamEvent? {
    let fields = (try? OrderedJSON(parsing: data))?.objectValue
    switch event {
    case .reset: return .reset
    case .user: return fields?.uuid("message").map { .user(message: $0) }
    case .lookup:
      guard let fields, let round = fields.integer("round"), let tool = fields["tool"]?.stringValue, let args = fields["args"]?.objectValue,
        let status = fields["status"]?.stringValue.flatMap(TurnLookupStatus.init(rawValue:))
      else { return nil }
      return .lookup(TurnLookupEvent(round: round, tool: tool, args: args, status: status))
    case .delta: return fields?["text"]?.stringValue.flatMap { $0.isEmpty ? nil : .delta($0) }
    case .change:
      guard let fields, let index = fields.integer("index"), let op = fields["op"]?.stringValue, let label = fields["label"]?.stringValue,
        let group = fields["group"]?.stringValue.flatMap(TurnChangeGroup.init(rawValue:))
      else { return nil }
      return .change(TurnChangeEvent(index: index, op: op, label: label, group: group))
    case .done: return fields?.uuid("reply").map { .done(reply: $0) }
    case .error:
      guard let fields, let code = fields["code"]?.stringValue, let message = fields["message"]?.stringValue else { return nil }
      return .error(TurnFailure(code: code, message: message))
    }
  }
}

extension TurnStreamEvent {
  // apps/novel-forge-server/src/modules/refinement/turn-stream.service.ts:66-76 and :96 name the payloads; a message and a reply travel as their ids.
  fileprivate var frameData: OrderedJSONObject {
    switch self {
    case .user(let message): OrderedJSONObject([("message", .string(message.uuidString.lowercased()))])
    case .lookup(let lookup):
      OrderedJSONObject([
        ("round", .int(Int64(lookup.round))), ("tool", .string(lookup.tool)), ("args", .object(lookup.args)), ("status", .string(lookup.status.rawValue)),
      ])
    case .delta(let text): OrderedJSONObject([("text", .string(text))])
    case .change(let change):
      OrderedJSONObject([
        ("index", .int(Int64(change.index))), ("op", .string(change.op)), ("label", .string(change.label)), ("group", .string(change.group.rawValue)),
      ])
    case .reset: OrderedJSONObject([])
    case .done(let reply): OrderedJSONObject([("reply", .string(reply.uuidString.lowercased()))])
    case .error(let failure): OrderedJSONObject([("code", .string(failure.code)), ("message", .string(failure.message))])
    }
  }
}

extension OrderedJSONObject {
  fileprivate func uuid(_ key: String) -> UUID? {
    self[key]?.stringValue.flatMap(UUID.init(uuidString:))
  }

  fileprivate func integer(_ key: String) -> Int? {
    guard case .int(let value)? = self[key], let integer = Int(exactly: value), integer >= 0 else { return nil }
    return integer
  }
}
