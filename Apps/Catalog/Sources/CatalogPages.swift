import SwiftUI

extension CatalogComponent {
  @ViewBuilder
  var page: some View {
    switch self {
    case .glass: GlassPage()
    case .button: ButtonPage()
    case .iconButton: IconButtonPage()
    case .card: CardPage()
    case .menu: MenuPage()
    case .confirmationDialog: ConfirmationDialogPage()
    case .textField: TextFieldPage()
    case .searchField: SearchFieldPage()
    case .textEditor: TextEditorPage()
    case .toggle: TogglePage()
    case .stepper: StepperPage()
    case .slider: SliderPage()
    case .segmentedControl: SegmentedControlPage()
    case .picker: PickerPage()
    case .datePicker: DatePickerPage()
    case .colorPicker: ColorPickerPage()
    case .fileImporter: FileImporterPage()
    case .oneTimeCodeField: OneTimeCodeFieldPage()
    case .tokenField: TokenFieldPage()
    case .rating: RatingPage()
    case .badge: BadgePage()
    case .tag: TagPage()
    case .avatar: AvatarPage()
    case .callout: CalloutPage()
    case .progressView: ProgressViewPage()
    case .skeleton: SkeletonPage()
    case .contentUnavailable: ContentUnavailablePage()
    case .statistic: StatisticPage()
    case .list: ListPage()
    case .labeledContent: LabeledContentPage()
    case .disclosureGroup: DisclosureGroupPage()
    case .outlineGroup: OutlineGroupPage()
    case .swipeActions: SwipeActionsPage()
    case .refreshControl: RefreshControlPage()
    case .notificationList: NotificationListPage()
    case .table: TablePage()
    case .chart: ChartPage()
    case .steps: StepsPage()
    case .timeline: TimelinePage()
    case .accountMenu: AccountMenuPage()
    case .commandPalette: CommandPalettePage()
    case .sheet: SheetPage()
    case .alert: AlertPage()
    case .popover: PopoverPage()
    case .toast: ToastPage()
    default: PendingComponentPage(component: self)
    }
  }
}

extension CatalogComponent {
  @ViewBuilder
  var demo: some View {
    switch self {
    case .tabBar: TabBarPage()
    case .navigationBar: NavigationBarPage()
    case .toolbar: ToolbarPage()
    case .sidebar: SidebarPage()
    case .splitView: SplitViewPage()
    case .inspector: InspectorPage()
    default: PendingDemo(component: self)
    }
  }
}
