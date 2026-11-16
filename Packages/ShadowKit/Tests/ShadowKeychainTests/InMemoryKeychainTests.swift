import Foundation
import ShadowKeychain
import ShadowTestSupport
import Testing

@Suite("InMemoryKeychain")
struct InMemoryKeychainTests {
  private let keychain = InMemoryKeychain()

  @Test("should return the same device for the same name")
  func returnsSameDevice() throws {
    try keychain.device("phone").store(service: "vault", scope: .device).setString("marker", forKey: "device")

    #expect(keychain.device("phone") === keychain.device("phone"))
    #expect(try keychain.device("phone").store(service: "vault", scope: .device).string(forKey: "device") == "marker")
  }

  @Test("should keep device and synced items separate under the same service and key")
  func separatesScopes() throws {
    let device = keychain.device("phone").store(service: "vault", scope: .device)
    let synced = keychain.device("phone").store(service: "vault", scope: .synced)

    try device.setString("local", forKey: "key")
    #expect(try synced.string(forKey: "key") == nil)
    #expect(try synced.insertString("shared", forKey: "key"))

    #expect(try device.string(forKey: "key") == "local")
    #expect(try synced.string(forKey: "key") == "shared")

    try synced.removeValue(forKey: "key")
    #expect(try device.string(forKey: "key") == "local")
    #expect(try synced.allKeys().isEmpty)
  }

  @Test("should keep services separate within a scope")
  func separatesServices() throws {
    let phone = keychain.device("phone")
    try phone.store(service: "vault-a", scope: .synced).setString("a", forKey: "key")

    #expect(try phone.store(service: "vault-b", scope: .synced).string(forKey: "key") == nil)
  }

  @Test("should never deliver device items to another device")
  func keepsDeviceItemsLocal() throws {
    let laptop = keychain.device("laptop")
    try keychain.device("phone").store(service: "vault", scope: .device).setString("marker", forKey: "device")

    keychain.deliver()

    #expect(try laptop.store(service: "vault", scope: .device).string(forKey: "device") == nil)
    #expect(try laptop.store(service: "vault", scope: .synced).string(forKey: "device") == nil)
  }

  @Test("should show a synced write on the writing device at once and on others only after delivery")
  func deliversLate() throws {
    let phone = keychain.device("phone").store(service: "vault", scope: .synced)
    let laptop = keychain.device("laptop").store(service: "vault", scope: .synced)

    #expect(try phone.insertString("key-1", forKey: "k1"))
    #expect(try phone.string(forKey: "k1") == "key-1")
    #expect(try laptop.string(forKey: "k1") == nil)
    #expect(try laptop.allKeys().isEmpty)

    keychain.deliver()

    #expect(try laptop.string(forKey: "k1") == "key-1")
    #expect(try laptop.allKeys() == ["k1"])
  }

  @Test("should deliver only to the named device")
  func deliversToOneDevice() throws {
    let phone = keychain.device("phone").store(service: "vault", scope: .synced)
    let laptop = keychain.device("laptop").store(service: "vault", scope: .synced)
    let tablet = keychain.device("tablet").store(service: "vault", scope: .synced)

    try phone.setString("key-1", forKey: "k1")
    keychain.deliver(to: "laptop")

    #expect(try laptop.string(forKey: "k1") == "key-1")
    #expect(try tablet.string(forKey: "k1") == nil)

    keychain.deliver(to: "tablet")
    #expect(try tablet.string(forKey: "k1") == "key-1")
  }

  @Test("should deliver existing synced items to a device that joins later")
  func deliversToLateDevice() throws {
    try keychain.device("phone").store(service: "vault", scope: .synced).setString("key-1", forKey: "k1")
    keychain.deliver()

    let laptop = keychain.device("laptop").store(service: "vault", scope: .synced)
    keychain.deliver()

    #expect(try laptop.string(forKey: "k1") == "key-1")
  }

  @Test("should let both devices insert the same synced key before delivery and keep only the last write")
  func resolvesConflictsByLastWrite() throws {
    let phone = keychain.device("phone").store(service: "vault", scope: .synced)
    let laptop = keychain.device("laptop").store(service: "vault", scope: .synced)
    let tablet = keychain.device("tablet").store(service: "vault", scope: .synced)

    #expect(try phone.insertString("from-phone", forKey: "k1"))
    #expect(try laptop.insertString("from-laptop", forKey: "k1"))

    keychain.deliver()

    #expect(try phone.string(forKey: "k1") == "from-laptop")
    #expect(try laptop.string(forKey: "k1") == "from-laptop")
    #expect(try tablet.string(forKey: "k1") == "from-laptop")
    #expect(try phone.insertString("again", forKey: "k1") == false)
  }

  @Test("should resolve conflicts by write order even when delivered out of order")
  func resolvesConflictsOutOfOrder() throws {
    let phone = keychain.device("phone").store(service: "vault", scope: .synced)
    let laptop = keychain.device("laptop").store(service: "vault", scope: .synced)

    try phone.setString("first", forKey: "k1")
    try laptop.setString("second", forKey: "k1")

    keychain.deliver(to: "laptop")
    #expect(try laptop.string(forKey: "k1") == "second")

    keychain.deliver(to: "phone")
    #expect(try phone.string(forKey: "k1") == "second")
  }

  @Test("should neither send nor receive while sync is disabled")
  func honoursDisabledSync() throws {
    let phoneDevice = keychain.device("phone")
    let phone = phoneDevice.store(service: "vault", scope: .synced)
    let laptop = keychain.device("laptop").store(service: "vault", scope: .synced)

    #expect(phoneDevice.isSyncEnabled)
    phoneDevice.setSyncEnabled(false)
    #expect(phoneDevice.isSyncEnabled == false)

    try phone.setString("from-phone", forKey: "k1")
    try laptop.setString("from-laptop", forKey: "k2")
    keychain.deliver()
    keychain.deliver(to: "phone")

    #expect(try laptop.string(forKey: "k1") == nil)
    #expect(try phone.string(forKey: "k2") == nil)

    phoneDevice.setSyncEnabled(true)
    keychain.deliver()

    #expect(try laptop.string(forKey: "k1") == "from-phone")
    #expect(try phone.string(forKey: "k2") == "from-laptop")
  }

  @Test("should propagate a synced delete on delivery")
  func propagatesDeletes() throws {
    let phone = keychain.device("phone").store(service: "vault", scope: .synced)
    let laptop = keychain.device("laptop").store(service: "vault", scope: .synced)

    try phone.setString("key-1", forKey: "k1")
    keychain.deliver()
    try laptop.removeValue(forKey: "k1")

    #expect(try phone.string(forKey: "k1") == "key-1")

    keychain.deliver()

    #expect(try phone.string(forKey: "k1") == nil)
    #expect(try phone.allKeys().isEmpty)
    #expect(try phone.insertString("key-2", forKey: "k1"))
  }

  @Test("should let a later write on another device win over an undelivered delete")
  func resolvesDeleteConflicts() throws {
    let phone = keychain.device("phone").store(service: "vault", scope: .synced)
    let laptop = keychain.device("laptop").store(service: "vault", scope: .synced)

    try phone.setString("key-1", forKey: "k1")
    keychain.deliver()
    try phone.removeValue(forKey: "k1")
    try laptop.setString("key-2", forKey: "k1")

    keychain.deliver()

    #expect(try phone.string(forKey: "k1") == "key-2")
    #expect(try laptop.string(forKey: "k1") == "key-2")
  }

  @Test("should leave exactly one winner when many tasks insert the same key on one device")
  func insertsConcurrently() async throws {
    let store = keychain.device("phone").store(service: "vault", scope: .synced)

    let winners = await withTaskGroup(of: Int?.self) { group in
      for index in 0..<200 {
        group.addTask { (try? store.insertString("value-\(index)", forKey: "k1")) == true ? index : nil }
      }
      return await group.reduce(into: [Int]()) { winners, winner in
        if let winner { winners.append(winner) }
      }
    }

    #expect(winners.count == 1)
    #expect(try store.string(forKey: "k1") == winners.first.map { "value-\($0)" })
  }
}
