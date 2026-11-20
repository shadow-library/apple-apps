import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.app(
  name: "NovelForge",
  platform: .phoneAndMac,
  dependencies: [.product(.novelForgeCore), .shared(.store), .shared(.ai), .shared(.jobs), .shared(.keychain), .shared(.networking), .shared(.designSystem), .shared(.text)],
  testDependencies: [.product(.novelForgeCore), .shared(.store), .shared(.keychain), .shared(.testSupport), .shared(.text)],
  infoPlist: [
    "UTExportedTypeDeclarations": [
      [
        "UTTypeIdentifier": "com.shadow.apps.novelforge.novel",
        "UTTypeDescription": "Novel Forge Package",
        "UTTypeConformsTo": ["public.zip-archive", "public.data"],
        "UTTypeTagSpecification": ["public.filename-extension": ["novel"], "public.mime-type": "application/x-novel"],
      ]
    ]
  ],
  capabilities: [
    .iCloud(),
    .pushNotifications,
    .remoteNotificationBackgroundMode,
    .keychainSharing,
    .camera(usage: "Novel Forge uses the camera to scan the QR code that another of your devices shows when it shares its vault key."),
    .macSandbox,
  ]
)
