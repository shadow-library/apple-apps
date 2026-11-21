import Foundation

/// One problem per source, each cleared by its own kind of success; the status shows the one that stops the most, the earlier source on a tie.
struct SyncAttentionSlots: Sendable, Equatable {
  /// From the vault's phase or the provider's condition.
  var phase: SyncAttentionReason?
  /// From a run that failed to reach storage or failed outright.
  var transient: SyncAttentionReason?
  var upload: SyncAttentionReason?
  var download: SyncAttentionReason?
  var clock: SyncAttentionReason?

  var current: SyncAttentionReason? {
    [phase, transient, upload, download, clock].compactMap(\.self).min { $0.stops.severity < $1.stops.severity }
  }
}
