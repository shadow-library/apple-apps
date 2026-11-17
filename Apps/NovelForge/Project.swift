import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.app(
  name: "NovelForge",
  platform: .phoneAndMac,
  dependencies: [.product(.novelForgeCore), .shared(.store), .shared(.designSystem)],
  testDependencies: [.product(.novelForgeCore), .shared(.store)]
)
