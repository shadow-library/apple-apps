import GRDB
import ShadowStore

public protocol ReadModel: Sendable, Equatable {
  associatedtype Input: Sendable

  static func load(_ input: Input, in transaction: ReadTransaction) throws(StoreError) -> Self
}

extension VaultStore {
  public func load<Model: ReadModel>(_: Model.Type, _ input: Model.Input) async throws(StoreError) -> Model {
    try await read { transaction in try Model.load(input, in: transaction) }
  }

  public func load<Model: ReadModel>(_ model: Model.Type) async throws(StoreError) -> Model where Model.Input == Void {
    try await load(model, ())
  }

  public func observe<Model: ReadModel>(_: Model.Type, _ input: Model.Input) -> AsyncThrowingStream<Model, any Error> {
    observeReads { transaction in try Model.load(input, in: transaction) }
  }

  public func observe<Model: ReadModel>(_ model: Model.Type) -> AsyncThrowingStream<Model, any Error> where Model.Input == Void {
    observe(model, ())
  }
}

extension ReadTransaction {
  func query<Result>(_ body: (Database) throws -> Result) throws(StoreError) -> Result {
    do {
      return try body(database)
    } catch {
      throw StoreError(projecting: error)
    }
  }
}
