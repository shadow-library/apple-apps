enum CatalogComponent: String, CaseIterable, Identifiable, Hashable, Sendable {
  case glass = "Glass"

  case button = "Button"
  case iconButton = "IconButton"
  case menu = "Menu"
  case confirmationDialog = "ConfirmationDialog"
  case swipeActions = "SwipeActions"

  case textField = "TextField"
  case searchField = "SearchField"
  case textEditor = "TextEditor"
  case tokenField = "TokenField"
  case picker = "Picker"
  case toggle = "Toggle"
  case segmentedControl = "SegmentedControl"
  case slider = "Slider"
  case stepper = "Stepper"
  case datePicker = "DatePicker"
  case colorPicker = "ColorPicker"
  case oneTimeCodeField = "OneTimeCodeField"
  case rating = "Rating"
  case fileImporter = "FileImporter"

  case navigationBar = "NavigationBar"
  case tabBar = "TabBar"
  case toolbar = "Toolbar"
  case sidebar = "Sidebar"
  case splitView = "SplitView"
  case accountMenu = "AccountMenu"
  case commandPalette = "CommandPalette"
  case steps = "Steps"

  case sheet = "Sheet"
  case alert = "Alert"
  case inspector = "Inspector"
  case popover = "Popover"

  case callout = "Callout"
  case toast = "Toast"
  case notificationList = "NotificationList"
  case badge = "Badge"
  case tag = "Tag"
  case progressView = "ProgressView"
  case skeleton = "Skeleton"
  case contentUnavailable = "ContentUnavailable"
  case refreshControl = "RefreshControl"

  case list = "List"
  case table = "Table"
  case labeledContent = "LabeledContent"
  case statistic = "Statistic"
  case chart = "Chart"
  case timeline = "Timeline"
  case outlineGroup = "OutlineGroup"
  case disclosureGroup = "DisclosureGroup"
  case card = "Card"
  case avatar = "Avatar"

  case iPhoneScreens = "iPhoneScreens"
  case iPadScreen = "iPadScreen"
  case macScreen = "MacScreen"

  var id: String { rawValue }
  var title: String { metadata.title }
  var systemImage: String { metadata.systemImage }
  var group: CatalogGroup { metadata.group }

  var layout: CatalogPageLayout {
    switch self {
    case .navigationBar, .tabBar, .toolbar, .sidebar, .splitView, .inspector, .iPhoneScreens, .iPadScreen, .macScreen: .fullBleed
    case .swipeActions, .refreshControl, .notificationList, .outlineGroup: .list
    default: .scroll
    }
  }

  private struct Metadata {
    let title: String
    let systemImage: String
    let group: CatalogGroup

    init(_ title: String, _ systemImage: String, _ group: CatalogGroup) {
      self.title = title
      self.systemImage = systemImage
      self.group = group
    }
  }

  private var metadata: Metadata {
    switch self {
    case .glass: Metadata("Glass", "drop", .glass)

    case .button: Metadata("Button", "button.horizontal", .actions)
    case .iconButton: Metadata("Icon button", "plus.circle", .actions)
    case .menu: Metadata("Menu", "ellipsis.circle", .actions)
    case .confirmationDialog: Metadata("Confirmation dialog", "exclamationmark.bubble", .actions)
    case .swipeActions: Metadata("Swipe actions", "arrow.left.arrow.right", .actions)

    case .textField: Metadata("Text field", "character.cursor.ibeam", .inputs)
    case .searchField: Metadata("Search field", "magnifyingglass", .inputs)
    case .textEditor: Metadata("Text editor", "text.alignleft", .inputs)
    case .tokenField: Metadata("Token field", "rectangle.and.pencil.and.ellipsis", .inputs)
    case .picker: Metadata("Picker", "filemenu.and.selection", .inputs)
    case .toggle: Metadata("Toggle", "switch.2", .inputs)
    case .segmentedControl: Metadata("Segmented control", "rectangle.split.3x1", .inputs)
    case .slider: Metadata("Slider", "slider.horizontal.3", .inputs)
    case .stepper: Metadata("Stepper", "plusminus", .inputs)
    case .datePicker: Metadata("Date picker", "calendar", .inputs)
    case .colorPicker: Metadata("Color picker", "paintpalette", .inputs)
    case .oneTimeCodeField: Metadata("One-time code field", "ellipsis.rectangle", .inputs)
    case .rating: Metadata("Rating", "star", .inputs)
    case .fileImporter: Metadata("File importer", "square.and.arrow.down", .inputs)

    case .navigationBar: Metadata("Navigation bar", "menubar.rectangle", .navigation)
    case .tabBar: Metadata("Tab bar", "dock.rectangle", .navigation)
    case .toolbar: Metadata("Toolbar", "wrench.and.screwdriver", .navigation)
    case .sidebar: Metadata("Sidebar", "sidebar.left", .navigation)
    case .splitView: Metadata("Split view", "rectangle.split.2x1", .navigation)
    case .accountMenu: Metadata("Account menu", "person.crop.circle", .navigation)
    case .commandPalette: Metadata("Command palette", "command", .navigation)
    case .steps: Metadata("Steps", "list.number", .navigation)

    case .sheet: Metadata("Sheet", "rectangle.bottomhalf.inset.filled", .presentation)
    case .alert: Metadata("Alert", "exclamationmark.triangle", .presentation)
    case .inspector: Metadata("Inspector", "sidebar.right", .presentation)
    case .popover: Metadata("Popover", "bubble.left", .presentation)

    case .callout: Metadata("Callout", "info.circle", .status)
    case .toast: Metadata("Toast", "text.bubble", .status)
    case .notificationList: Metadata("Notification list", "bell", .status)
    case .badge: Metadata("Badge", "app.badge", .status)
    case .tag: Metadata("Tag", "tag", .status)
    case .progressView: Metadata("Progress view", "progress.indicator", .status)
    case .skeleton: Metadata("Skeleton", "rectangle.dashed", .status)
    case .contentUnavailable: Metadata("Content unavailable", "tray", .status)
    case .refreshControl: Metadata("Refresh control", "arrow.clockwise", .status)

    case .list: Metadata("List", "list.bullet", .data)
    case .table: Metadata("Table", "tablecells", .data)
    case .labeledContent: Metadata("Labeled content", "list.bullet.rectangle", .data)
    case .statistic: Metadata("Statistic", "number", .data)
    case .chart: Metadata("Chart", "chart.xyaxis.line", .data)
    case .timeline: Metadata("Timeline", "clock.arrow.circlepath", .data)
    case .outlineGroup: Metadata("Outline group", "list.bullet.indent", .data)
    case .disclosureGroup: Metadata("Disclosure group", "chevron.down.square", .data)
    case .card: Metadata("Card", "rectangle", .data)
    case .avatar: Metadata("Avatar", "person.circle", .data)

    case .iPhoneScreens: Metadata("iPhone screens", "iphone", .screens)
    case .iPadScreen: Metadata("iPad screen", "ipad", .screens)
    case .macScreen: Metadata("Mac screen", "macbook", .screens)
    }
  }
}

enum CatalogPageLayout: Sendable {
  case scroll
  case list
  case fullBleed
}
