/// The thresholds of savings and goals, from the approved plan.
public enum SavingsRules {
  /// At most this many goals are active at once; two devices creating at the same time can leave more, which every read still orders.
  public static let maximumActiveGoals = 3
  /// A goal can be bought from this many days after the day it was created.
  public static let coolingOffDays = 3
  /// A goal earns its milestones and its purchase reward only with a target of at least this share of Home's monthly limit, in thousandths.
  public static let rewardTargetThousandths: Int64 = 250
  /// A month's deposit reference is the typical month times this, in thousandths, capped at the limit.
  public static let referenceThousandths: Int64 = 1100
  /// The pace is the mean of the deposits of up to this many closed months.
  public static let paceMonths = 3
  /// The pace is known once this many months have closed after the vault's first deposit-capable close.
  public static let paceCalibrationMonths = 2
  /// The lever: spending this share less in a category, in thousandths.
  public static let leverThousandths: Int64 = 100
  /// The lever's spending is the mean over this many complete months before the current one.
  public static let leverMonths = 3
}
