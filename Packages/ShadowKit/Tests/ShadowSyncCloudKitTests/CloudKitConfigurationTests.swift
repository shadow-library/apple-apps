import ShadowSyncCloudKit
import Testing

@Suite("CloudKitConfiguration", TestTimeLimit.quick)
struct CloudKitConfigurationTests {
  @Test("should keep the container and default to the vault zone")
  func defaultsZone() throws {
    let configuration = try CloudKitConfiguration(containerIdentifier: "iCloud.com.shadow.apps.novelforge")

    #expect(configuration.containerIdentifier == "iCloud.com.shadow.apps.novelforge")
    #expect(configuration.zoneName == "vault-default")
  }

  @Test("should refuse a container without the iCloud prefix or a name")
  func refusesContainers() {
    #expect(throws: CloudKitConfigurationError.invalidContainer("com.shadow.apps.novelforge")) { try CloudKitConfiguration(containerIdentifier: "com.shadow.apps.novelforge") }
    #expect(throws: CloudKitConfigurationError.invalidContainer("iCloud.")) { try CloudKitConfiguration(containerIdentifier: "iCloud.") }
  }

  @Test("should refuse an empty zone name and one CloudKit reserves")
  func refusesZones() {
    #expect(throws: CloudKitConfigurationError.invalidZoneName("")) { try CloudKitConfiguration(containerIdentifier: "iCloud.com.shadow.apps.a", zoneName: "") }
    #expect(throws: CloudKitConfigurationError.invalidZoneName("_defaultZone")) {
      try CloudKitConfiguration(containerIdentifier: "iCloud.com.shadow.apps.a", zoneName: "_defaultZone")
    }
  }
}
