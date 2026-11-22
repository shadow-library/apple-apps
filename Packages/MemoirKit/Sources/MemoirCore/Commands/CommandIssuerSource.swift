import ShadowStore

/// Where a writer gets its `CommandIssuer` for each command: resolved from the main store as the command's write sees it, so the clock is the account's
/// zone at that moment (a staged zone that has taken over, a zone merged from another device) and never one fixed when the writer was built.
public struct CommandIssuerSource: Sendable {
  private let resolve: @Sendable (ReadTransaction) throws -> CommandIssuer

  public init(_ resolve: @escaping @Sendable (ReadTransaction) throws -> CommandIssuer) {
    self.resolve = resolve
  }

  public func issuer(in transaction: ReadTransaction) throws -> CommandIssuer {
    try resolve(transaction)
  }

  /// The issuer as `store`'s open write sees it.
  public func issuer(in transaction: borrowing WriteTransaction, of store: VaultStore) throws -> CommandIssuer {
    try resolve(ReadTransaction(database: transaction.database, registry: store.registry))
  }
}
