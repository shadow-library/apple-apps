import GRDB

public enum ChangeOrigin: Sendable, Equatable {
  case local
  case remote
  case upgrade
}

/// Read merged state through ReadTransaction(database:registry:); the kernel's tables must never be written.
public protocol StoreReconciler: Sendable {
  func reconcile(_ touched: [EntityRef], origin: ChangeOrigin, in database: Database) throws
  /// Called when the vault scope has been cleared: product tables must drop everything they projected.
  func reset(in database: Database) throws
}

struct TouchedRefs {
  private(set) var vault: Set<EntityRef> = []
  private(set) var own: Set<EntityRef> = []

  mutating func insert(_ ref: EntityRef, scope: StateScope) {
    switch scope {
    case .vault: vault.insert(ref)
    case .own: own.insert(ref)
    }
  }

  func refs(in scope: StateScope) -> Set<EntityRef> {
    switch scope {
    case .vault: vault
    case .own: own
    }
  }
}

struct Settlement {
  let registry: SchemaRegistry
  let reconciler: (any StoreReconciler)?

  func settle(_ touched: TouchedRefs, origin: ChangeOrigin, in db: Database) throws(StoreError) -> [EntityRef] {
    try prune(touched, in: db)
    return try reconcile(touched, origin: origin, in: db)
  }

  func prune(_ touched: TouchedRefs, in db: Database) throws(StoreError) {
    let retention = RetentionRoutine(registry: registry)
    for scope in StateScope.allCases { try retention.prune(touched.refs(in: scope), scope: scope, in: db) }
  }

  func reset(in db: Database) throws(StoreError) {
    guard let reconciler else { return }
    do {
      try reconciler.reset(in: db)
    } catch {
      throw .reconcilerFailed(error)
    }
  }

  func reconcile(_ touched: TouchedRefs, origin: ChangeOrigin, in db: Database) throws(StoreError) -> [EntityRef] {
    let refs = touched.vault.sorted()
    guard !refs.isEmpty, let reconciler else { return refs }
    do {
      try reconciler.reconcile(refs, origin: origin, in: db)
    } catch {
      throw .reconcilerFailed(error)
    }
    return refs
  }
}
