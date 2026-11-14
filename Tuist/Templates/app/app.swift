import ProjectDescription

let name: Template.Attribute = .required("name")
let platform: Template.Attribute = .optional("platform", default: "ios")

let template = Template(
  description: "A new app under Apps/ wired to the shared ShadowKit modules",
  attributes: [name, platform],
  items: [
    .string(
      path: "Apps/\(name)/Project.swift",
      contents: """
        import ProjectDescription
        import ProjectDescriptionHelpers

        let project = Project.app(
          name: "\(name)",
          platform: .\(platform),
          dependencies: [.shared(.designSystem)]
        )

        """
    ),
    .string(
      path: "Apps/\(name)/Sources/\(name)App.swift",
      contents: """
        import SwiftUI

        @main
        struct \(name)App: App {
          var body: some Scene {
            WindowGroup {
              ContentView()
            }
          }
        }

        """
    ),
    .string(
      path: "Apps/\(name)/Sources/ContentView.swift",
      contents: """
        import ShadowDesignSystem
        import SwiftUI

        struct ContentView: View {
          var body: some View {
            Text("\(name)")
              .font(.largeTitle)
              .padding(Spacing.space4)
          }
        }

        #Preview {
          ContentView()
        }

        """
    ),
    .string(
      path: "Apps/\(name)/Tests/\(name)Tests.swift",
      contents: """
        import Testing

        @testable import \(name)

        @Suite("\(name)")
        struct \(name)Tests {
          @Test("should launch")
          func launches() {
            #expect(Bool(true))
          }
        }

        """
    ),
    .string(path: "Apps/\(name)/Resources/Assets.xcassets/Contents.json", contents: #"{ "info" : { "author" : "xcode", "version" : 1 } }"# + "\n"),
    .string(
      path: "Apps/\(name)/Resources/Assets.xcassets/AccentColor.colorset/Contents.json",
      contents: #"{ "colors" : [ { "idiom" : "universal" } ], "info" : { "author" : "xcode", "version" : 1 } }"# + "\n"
    ),
  ]
)
