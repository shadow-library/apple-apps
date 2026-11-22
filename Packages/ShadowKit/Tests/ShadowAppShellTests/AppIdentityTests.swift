import Testing

@testable import ShadowAppShell

@Suite("AppIdentity", TestTimeLimit.quick)
struct AppIdentityTests {
  @Test("should name the keychain services and defaults keys under the app's id")
  func shouldNameKeychainServicesAndDefaultsKeysUnderTheAppsID() {
    let app = AppIdentity.fixture

    #expect(app.aiKeychainService == "com.shadow.apps.shelltest.ai")
    #expect(app.aiSettingsKey == "com.shadow.apps.shelltest.ai.settings.v1")
    #expect(app.recoveryRecipientKeyPrefix == "com.shadow.apps.shelltest.sync.recovery-recipient.")
    #expect(app.recoveryOfferDeclinedKeyPrefix == "com.shadow.apps.shelltest.sync.recovery-offer-declined.")
  }
}
