import Foundation
import ShadowKeychain
import Synchronization

public final class InMemoryKeychain: Sendable {
  public enum Scope: Sendable {
    case device
    case synced
  }

  public final class Device: Sendable {
    private let name: String
    private let storage: Storage

    fileprivate init(name: String, storage: Storage) {
      self.name = name
      self.storage = storage
    }

    public var isSyncEnabled: Bool {
      storage.state.withLock { $0.devices[name]?.isSyncEnabled ?? true }
    }

    public func setSyncEnabled(_ enabled: Bool) {
      storage.state.withLock { $0.devices[name, default: DeviceState()].isSyncEnabled = enabled }
    }

    public func store(service: String, scope: Scope) -> any SecureStore {
      DeviceStore(device: name, namespace: Namespace(service: service, scope: scope), storage: storage)
    }
  }

  private let storage = Storage()
  private let devices = Mutex<[String: Device]>([:])

  public init() {}

  public func device(_ name: String) -> Device {
    devices.withLock { devices in
      if let device = devices[name] { return device }
      let device = Device(name: name, storage: storage)
      storage.state.withLock { $0.devices[name] = DeviceState() }
      devices[name] = device
      return device
    }
  }

  public func deliver() {
    storage.state.withLock { $0.deliver(to: Array($0.devices.keys)) }
  }

  public func deliver(to deviceName: String) {
    storage.state.withLock { $0.deliver(to: [deviceName]) }
  }
}

private struct Namespace: Hashable, Sendable {
  let service: String
  let scope: InMemoryKeychain.Scope
}

private struct Entry: Sendable {
  let value: Data?
  let version: UInt64
}

private typealias Items = [Namespace: [String: Entry]]

private struct DeviceState: Sendable {
  var isSyncEnabled = true
  var items: Items = [:]
}

private struct State: Sendable {
  var devices: [String: DeviceState] = [:]
  var cloud: Items = [:]
  var clock: UInt64 = 0

  func value(forKey key: String, in namespace: Namespace, on device: String) -> Data? {
    devices[device]?.items[namespace]?[key]?.value
  }

  mutating func write(_ value: Data?, forKey key: String, in namespace: Namespace, on device: String) {
    clock += 1
    devices[device, default: DeviceState()].items[namespace, default: [:]][key] = Entry(value: value, version: clock)
  }

  mutating func deliver(to recipients: [String]) {
    for sender in devices.values where sender.isSyncEnabled { Self.merge(sender.items, into: &cloud) }
    for recipient in recipients {
      guard var device = devices[recipient], device.isSyncEnabled else { continue }
      Self.merge(cloud, into: &device.items)
      devices[recipient] = device
    }
  }

  private static func merge(_ source: Items, into target: inout Items) {
    for (namespace, entries) in source where namespace.scope == .synced {
      for (key, entry) in entries where entry.version > target[namespace]?[key]?.version ?? 0 {
        target[namespace, default: [:]][key] = entry
      }
    }
  }
}

private final class Storage: Sendable {
  let state = Mutex(State())
}

private struct DeviceStore: SecureStore {
  let device: String
  let namespace: Namespace
  let storage: Storage

  func data(forKey key: String) throws(SecureStoreError) -> Data? {
    storage.state.withLock { $0.value(forKey: key, in: namespace, on: device) }
  }

  func setData(_ data: Data, forKey key: String) throws(SecureStoreError) {
    storage.state.withLock { $0.write(data, forKey: key, in: namespace, on: device) }
  }

  func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool {
    storage.state.withLock { state in
      guard state.value(forKey: key, in: namespace, on: device) == nil else { return false }
      state.write(data, forKey: key, in: namespace, on: device)
      return true
    }
  }

  func removeValue(forKey key: String) throws(SecureStoreError) {
    storage.state.withLock { state in
      guard state.value(forKey: key, in: namespace, on: device) != nil else { return }
      state.write(nil, forKey: key, in: namespace, on: device)
    }
  }

  func allKeys() throws(SecureStoreError) -> [String] {
    storage.state.withLock { state in
      let entries = state.devices[device]?.items[namespace] ?? [:]
      return entries.filter { $0.value.value != nil }.keys.sorted()
    }
  }
}
