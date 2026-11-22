import Foundation
import NovelForgeCore
import OSLog
import Observation
import ShadowAppShell
import ShadowCore
import ShadowStore
import ShadowSync

/// The vault's devices as its replica directory lists them, with this device always among them, and which of them runs the vault's jobs.
@MainActor
@Observable
final class DevicesModel {
  struct Device: Identifiable, Hashable {
    let replica: ReplicaID
    let name: String?
    let platform: String?
    let isHere: Bool

    var id: ReplicaID { replica }
  }

  nonisolated private static let logger = Logger(subsystem: "com.shadow.apps.novelforge", category: "worker")

  private(set) var devices: [Device] = []
  /// Nil while no job engine runs on the vault in this copy of the app.
  private(set) var worker: VaultWorker?

  /// Until cancelled; the directory changes as devices join, are named or retire.
  func followDevices(in store: VaultStore) async {
    let entries = store.observeReads { transaction in try ReplicaDirectory.read(in: transaction).replicas.filter { $0.state == .active } }
    do {
      for try await active in entries {
        let listed = await Self.devices(active, in: store)
        guard !Task.isCancelled else { return }
        devices = listed
      }
    } catch is CancellationError {
      return
    } catch {
      Self.logger.error("Stopped following the vault's devices")
    }
  }

  func followWorker(_ engine: JobEngine?) async {
    worker = nil
    guard let engine else { return }
    do {
      for try await current in engine.observeWorker() {
        guard !Task.isCancelled else { return }
        worker = current
      }
    } catch is CancellationError {
      return
    } catch {
      Self.logger.error("Stopped following the vault's worker")
    }
  }

  /// This device first, then by name; names come from `SyncRuntimes.deviceNames`, as every other screen that names a device.
  nonisolated static func devices(_ entries: [ReplicaEntry], in store: VaultStore) async -> [Device] {
    let here = store.replica
    let replicas = Set(entries.map(\.replica)).union([here])
    let names = await SyncRuntimes.deviceNames(for: replicas, in: store)
    let platforms = Dictionary(entries.map { ($0.replica, $0.platform) }) { first, _ in first }
    return replicas.map { Device(replica: $0, name: names[$0], platform: platforms[$0] ?? nil, isHere: $0 == here) }
      .sorted { first, second in
        if first.isHere != second.isHere { return first.isHere }
        return (first.name ?? "", first.replica) < (second.name ?? "", second.replica)
      }
  }
}
