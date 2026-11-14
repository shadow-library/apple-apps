import SwiftUI

extension CatalogComponent {
  @ViewBuilder
  var page: some View {
    switch self {
    case .glass: GlassPage()
    case .button: ButtonPage()
    case .iconButton: IconButtonPage()
    case .card: CardPage()
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
    default: PendingComponentPage(component: self)
    }
  }
}
