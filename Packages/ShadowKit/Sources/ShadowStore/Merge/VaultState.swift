import Foundation
import ShadowCore

public struct VaultState: Sendable, Equatable {
  var entities: [EntityRef: EntityState]
  var foreignRecords: [Data: ChangeRecord]
  var opaque: Set<Data>

  public init() {
    entities = [:]
    foreignRecords = [:]
    opaque = []
  }

  init(_ change: ChangeRecord, registry: SchemaRegistry) {
    self.init()
    let interpretation = registry.interpretation(of: change)
    if let state = interpretation.state { entities[change.ref] = state }
    if let remainder = interpretation.foreign { foreignRecords[remainder.canonicalBytes()] = remainder }
  }

  public mutating func apply(_ change: ChangeRecord, registry: SchemaRegistry) {
    let ref = change.ref
    let interpretation = registry.interpretation(of: change)
    if let state = interpretation.state { entities[ref] = entities[ref].map { $0.joined(with: state) } ?? state }
    if let remainder = interpretation.foreign, remainder.kind == .purge || !isPurged(ref) { foreignRecords[remainder.canonicalBytes()] = remainder }
    if interpretation.state?.isPurged == true || interpretation.foreign?.absorbsForeign == true { dropForeign(of: ref) }
  }

  public mutating func keepOpaque(_ line: Data) {
    opaque.insert(line)
  }

  /// The join laws hold for states built under registries on one additive chain.
  public mutating func merge(_ other: VaultState) {
    entities.merge(other.entities) { $0.joined(with: $1) }
    foreignRecords.merge(other.foreignRecords) { mine, _ in mine }
    opaque.formUnion(other.opaque)
    dropForeignOfPurged()
  }

  public func merging(_ other: VaultState) -> VaultState {
    var copy = self
    copy.merge(other)
    return copy
  }

  public mutating func reinterpretForeign(registry: SchemaRegistry) throws(VaultStateError) {
    for ref in refs {
      guard let state = entities[ref], let problem = state.incompatibility(ref, registry: registry) else { continue }
      throw .incompatibleRegistry(problem)
    }
    for (ref, state) in entities {
      guard let schema = registry[ref.kind] else { continue }
      entities[ref] = state.restamped(with: schema)
    }
    for (bytes, record) in foreignRecords {
      let interpretation = registry.interpretation(of: record)
      guard interpretation.foreign?.canonicalBytes() != bytes else { continue }
      foreignRecords[bytes] = nil
      merge(VaultState(record, registry: registry))
    }
  }

  private mutating func dropForeignOfPurged() {
    let absorbed = Set(foreignRecords.values.filter(\.absorbsForeign).map(\.ref))
    for (bytes, record) in foreignRecords where record.kind != .purge && (entities[record.ref]?.isPurged == true || absorbed.contains(record.ref)) {
      foreignRecords[bytes] = nil
    }
  }

  private mutating func dropForeign(of ref: EntityRef) {
    for (bytes, record) in foreignRecords where record.kind != .purge && record.ref == ref { foreignRecords[bytes] = nil }
  }

  private func isPurged(_ ref: EntityRef) -> Bool {
    entities[ref]?.isPurged == true || foreignRecords.values.contains { $0.absorbsForeign && $0.ref == ref }
  }

  public var foreign: [ChangeRecord] {
    foreignRecords.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map(\.value)
  }

  public var opaqueLines: [Data] {
    opaque.sorted { $0.lexicographicallyPrecedes($1) }
  }

  public func state(of ref: EntityRef) -> EntityState? {
    entities[ref]
  }

  public var refs: [EntityRef] {
    entities.keys.sorted()
  }

  public var isEmpty: Bool {
    entities.isEmpty && foreignRecords.isEmpty && opaque.isEmpty
  }
}

extension EntityState {
  func incompatibility(_ ref: EntityRef, registry: SchemaRegistry) -> String? {
    guard let schema = registry[ref.kind] else { return "kind \(ref.kind) is no longer declared" }
    let fields: [ExactString: FieldState]
    let marks: [ExactString]
    switch self {
    case .purged: return nil
    case .appended: (fields, marks) = ([:], [])
    case .record(let state): (fields, marks) = (state.fields, [])
    case .revisioned(let state): (fields, marks) = (state.fields, Array(state.marks.keys))
    }
    guard shapeName.utf8.elementsEqual(schema.shape.name.utf8) else { return "\(ref.kind)/\(ref.key) is \(shapeName) but the kind is declared \(schema.shape.name)" }
    for (name, field) in fields.sorted(by: { $0.key < $1.key }) {
      guard let declared = schema.rule(forField: name.value) else { return "field \(ref.kind).\(name) is no longer declared" }
      guard declared.canonicalBytes == field.rule.canonicalBytes || field.rule.isExtended(by: declared) else {
        return "field \(ref.kind).\(name) holds \(field.rule.summary), which \(declared.summary) does not extend"
      }
    }
    for mark in marks.sorted() where !schema.declaresMark(mark.value) { return "mark \(ref.kind).\(mark) is no longer declared" }
    return nil
  }

  func restamped(with schema: EntitySchema) -> EntityState {
    switch self {
    case .record(let state): .record(RecordState(fields: Self.restamped(state.fields, schema)))
    case .revisioned(let state): .revisioned(state.with(fields: Self.restamped(state.fields, schema)))
    case .appended, .purged: self
    }
  }

  private static func restamped(_ fields: [ExactString: FieldState], _ schema: EntitySchema) -> [ExactString: FieldState] {
    fields.reduce(into: [:]) { result, field in
      result[field.key] = schema.rule(forField: field.key.value).map { field.value.restamped(with: $0) } ?? field.value
    }
  }
}
