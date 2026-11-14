enum CatalogGroup: String, CaseIterable, Identifiable, Sendable {
  case foundations
  case glass
  case actions
  case inputs
  case navigation
  case presentation
  case status
  case data
  case screens

  var id: String { rawValue }

  var title: String {
    switch self {
    case .foundations: "Foundations"
    case .glass: "Glass"
    case .actions: "Actions"
    case .inputs: "Inputs"
    case .navigation: "Navigation"
    case .presentation: "Presentation"
    case .status: "Status and feedback"
    case .data: "Data"
    case .screens: "Screens"
    }
  }

  var pages: [CatalogPage] {
    CatalogPage.all.filter { $0.group == self }
  }
}
