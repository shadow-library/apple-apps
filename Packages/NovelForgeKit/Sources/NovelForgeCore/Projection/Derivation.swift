import GRDB
import ShadowStore

public protocol Derivation: Sendable {
  associatedtype Key: Hashable & Sendable
  associatedtype Output: FetchableRecord & PersistableRecord & Hashable & Sendable

  /// Raise it when `outputs(for:in:)` changes meaning; any change to the layout rebuilds every derived table at the next open.
  static var version: Int { get }
  /// Creates `Output.databaseTableName`, which must start with `nf_derived_` and have a primary key, and indexes on it; nothing else.
  static var definition: String { get }

  var inputs: [DerivationInput<Key>] { get }

  static func key(of output: Output) -> Key
  static func request(for key: Key) -> QueryInterfaceRequest<Output>

  func allKeys(in context: DerivationContext) throws(StoreError) -> Set<Key>
  /// Runs read-only; reads merged state and earlier derivations' tables, never its own.
  func outputs(for key: Key, in context: DerivationContext) throws(StoreError) -> [Output]
}

public struct DerivationInput<Key: Hashable & Sendable>: Sendable {
  let upstream: String?
  let keys: @Sendable (ProjectionChanges) -> [Key]

  /// Maps from the ref alone, never from state: a purged or half-delivered entity cannot say where it belonged. A per-novel aggregate over a
  /// hash-keyed kind subscribes to `RecordIndexDerivation` instead, whose row changes whenever the entity's merged state does, or to a per-ref layer of its own
  /// whose rows record the novel and chapter.
  public static func records(_ kinds: [NovelForgeKind], keys: @escaping @Sendable (EntityRef) -> [Key]) -> DerivationInput {
    let kinds = Set(kinds)
    return DerivationInput(upstream: nil) { changes in
      changes.touched.filter { NovelForgeKind($0.kind).map(kinds.contains) ?? false }.flatMap(keys)
    }
  }

  /// `keys` sees every row that appeared or disappeared, so a key is reached both by what it used to read and by what it reads now.
  public static func outputs<Upstream: Derivation>(of _: Upstream.Type, keys: @escaping @Sendable (Upstream.Output) -> [Key]) -> DerivationInput {
    DerivationInput(upstream: Upstream.Output.databaseTableName) { changes in
      changes.outputs(of: Upstream.self).flatMap(keys)
    }
  }
}

public struct DerivationContext {
  public let records: ReadTransaction

  public func refs(of kind: NovelForgeKind) throws(StoreError) -> [EntityRef] {
    try records.states(ofKind: kind.entityKind, scope: .vault).map(\.ref)
  }

  public func read<T>(_ body: (Database) throws -> T) throws(StoreError) -> T {
    do {
      return try body(records.database)
    } catch let error as DatabaseError where error.resultCode == .SQLITE_READONLY {
      throw .invalidChange("a derivation tried to write while it was reading")
    } catch {
      throw StoreError(projecting: error)
    }
  }

  public func fetchAll<Output: FetchableRecord>(_ request: QueryInterfaceRequest<Output>) throws(StoreError) -> [Output] {
    try read { database in try request.fetchAll(database) }
  }
}

struct ProjectionChanges {
  let touched: [EntityRef]
  private var changed: [String: [any Sendable]] = [:]

  init(touched: [EntityRef]) {
    self.touched = touched
  }

  func outputs<Upstream: Derivation>(of _: Upstream.Type) -> [Upstream.Output] {
    (changed[Upstream.Output.databaseTableName] ?? []).compactMap { $0 as? Upstream.Output }
  }

  mutating func record<Changed: Derivation>(_: Changed.Type, _ outputs: Set<Changed.Output>) {
    guard !outputs.isEmpty else { return }
    changed[Changed.Output.databaseTableName, default: []].append(contentsOf: outputs.map { $0 as any Sendable })
  }
}

extension StoreError {
  init(projecting error: any Error) {
    switch error {
    case let error as StoreError: self = error
    case let error as DatabaseError: self = .database("SQLite error \(error.extendedResultCode.rawValue): \(error.message ?? "no message")")
    default: self = .aborted(error)
    }
  }
}
