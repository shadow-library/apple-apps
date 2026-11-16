import ShadowCore
import ShadowStore

public enum ProjectionError: ShadowError {
  case invalidTableName(String)
  case duplicateTable(String)
  case upstreamNotBefore(table: String, upstream: String)
  case missingTable(String)
  case missingPrimaryKey(String)
  case definitionOutsideTable(table: String, object: String)
  case store(StoreError)

  public var code: String {
    switch self {
    case .invalidTableName: "projection.invalid_table_name"
    case .duplicateTable: "projection.duplicate_table"
    case .upstreamNotBefore: "projection.upstream_not_before"
    case .missingTable: "projection.missing_table"
    case .missingPrimaryKey: "projection.missing_primary_key"
    case .definitionOutsideTable: "projection.definition_outside_table"
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidTableName(let table): "Derived table \(table) must be named nf_derived_ followed by lower-case letters, digits and underscores."
    case .duplicateTable(let table): "Derived table \(table) is registered twice."
    case .upstreamNotBefore(let table, let upstream): "Derived table \(table) reads \(upstream), which is not registered before it."
    case .missingTable(let table): "The definition of derived table \(table) does not create it."
    case .missingPrimaryKey(let table): "Derived table \(table) has no declared primary key."
    case .definitionOutsideTable(let table, let object): "The definition of derived table \(table) creates or drops \(object), which is not the table or an index on it."
    case .store(let error): error.errorDescription
    }
  }
}
