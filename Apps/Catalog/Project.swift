import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.app(
  name: "Catalog",
  platform: .multiplatform,
  dependencies: [.shared(.designSystem)],
  includesUITests: true,
  accentColor: true
)
