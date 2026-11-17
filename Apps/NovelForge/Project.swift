import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.app(
  name: "NovelForge",
  platform: .phoneAndMac,
  dependencies: [.product(.novelForgeCore), .shared(.store), .shared(.ai), .shared(.keychain), .shared(.networking), .shared(.designSystem)],
  testDependencies: [.product(.novelForgeCore), .shared(.store)]
)
