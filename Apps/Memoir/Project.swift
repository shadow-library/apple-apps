import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.app(
  name: "Memoir",
  platform: .phoneAndMac,
  dependencies: [
    .product(.memoirCore), .shared(.core), .shared(.store), .shared(.ai), .shared(.jobs), .shared(.sync), .shared(.syncRuntime), .shared(.designSystem), .shared(.appShell),
  ],
  testDependencies: [
    .product(.memoirCore), .shared(.core), .shared(.store), .shared(.sync), .shared(.syncRuntime), .shared(.keychain), .shared(.testSupport), .shared(.appShell),
  ],
  capabilities: [
    .iCloud(),
    .pushNotifications,
    .remoteNotificationBackgroundMode,
    .keychainSharing,
    .camera(usage: "Memoir uses the camera to photograph receipts and to scan the QR code that another of your devices shows when it shares its vault key."),
    .macSandbox,
    .healthKit(
      usage:
        "Memoir reads your steps, active energy, water, weight, resting heart rate, waist, sleep and workouts from Health to fill in your daily metrics. It never writes to Health."
    ),
  ]
)
