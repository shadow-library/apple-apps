enum CatalogSection: String, CaseIterable, Identifiable {
  case buttons
  case cards
  case spacing

  var id: Self { self }

  var title: String {
    switch self {
    case .buttons: "Buttons"
    case .cards: "Cards"
    case .spacing: "Spacing"
    }
  }

  var systemImage: String {
    switch self {
    case .buttons: "button.horizontal"
    case .cards: "rectangle.on.rectangle"
    case .spacing: "ruler"
    }
  }
}
