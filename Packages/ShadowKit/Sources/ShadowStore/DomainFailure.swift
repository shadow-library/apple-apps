import ShadowCore

/// A product core's own error: an app presents it with its code, or as the store failure it wraps.
public protocol DomainFailure: ShadowError {
  var storeFailure: StoreError? { get }
}
