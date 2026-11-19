import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.app(
  name: "NovelForge",
  platform: .phoneAndMac,
  dependencies: [.product(.novelForgeCore), .shared(.store), .shared(.ai), .shared(.jobs), .shared(.keychain), .shared(.networking), .shared(.designSystem)],
  testDependencies: [.product(.novelForgeCore), .shared(.store), .shared(.keychain), .shared(.testSupport)],
  infoPlist: [
    "UTExportedTypeDeclarations": [
      [
        "UTTypeIdentifier": "com.shadow.apps.novelforge.novel",
        "UTTypeDescription": "Novel Forge Package",
        "UTTypeConformsTo": ["public.zip-archive", "public.data"],
        "UTTypeTagSpecification": ["public.filename-extension": ["novel"], "public.mime-type": "application/x-novel"],
      ]
    ]
  ]
)
