// apps/novel-forge-server/src/modules/ai/schemas/enums.ts:13
public enum HookType: String, CaseIterable, Codable, Sendable {
  case cliffhanger
  case revelation
  case quietDread = "quiet_dread"
  case promise
  case turn
  case closureWithMomentum = "closure_with_momentum"
  case earnedRest = "earned_rest"
}
