public struct CatalogResolution: Sendable, Equatable {
  public let catalog: ModelCatalog
  public let notices: [CatalogNotice]

  public init(catalog: ModelCatalog, notices: [CatalogNotice]) {
    self.catalog = catalog
    self.notices = notices
  }
}

public enum CatalogNotice: Sendable, Equatable {
  case retiringSoon(model: String, on: CatalogDate, daysLeft: Int)
  case replaced(model: String, by: String)
  case unavailable(model: String)
}
