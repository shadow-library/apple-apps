import ShadowText

struct VolumeChapterRow: Equatable, Sendable {
  var number: Int
  var wordCount: Int?
}

struct VolumeStats: Equatable, Sendable {
  var chapterCount: Int
  var firstChapter: Int?
  var lastChapter: Int?
  var wordCount: Int
}

// apps/novel-forge-server/src/common/volume-stats.ts:19
let emptyVolumeStats = VolumeStats(chapterCount: 0, firstChapter: nil, lastChapter: nil, wordCount: 0)

// apps/novel-forge-server/src/common/volume-stats.ts:22
func deriveVolumeStats(_ rows: [VolumeChapterRow]) -> VolumeStats {
  let numbers = rows.map(\.number)
  guard let first = numbers.min(), let last = numbers.max() else { return emptyVolumeStats }
  let words = rows.reduce(0) { sum, row in
    let (total, overflow) = sum.addingReportingOverflow(row.wordCount ?? 0)
    return overflow ? (row.wordCount ?? 0) < 0 ? Int.min : Int.max : total
  }
  return VolumeStats(chapterCount: rows.count, firstChapter: first, lastChapter: last, wordCount: words)
}

struct VolumePlanRange: Equatable, Sendable {
  var planChapterCount: Int
  var planFirstChapter: Int?
  var planLastChapter: Int?
}

// apps/novel-forge-server/src/common/volume-stats.ts:39
let emptyVolumePlanRange = VolumePlanRange(planChapterCount: 0, planFirstChapter: nil, planLastChapter: nil)

// apps/novel-forge-server/src/common/volume-stats.ts:46
func deriveVolumePlanRange(_ chapterNumbers: [Int]) -> VolumePlanRange {
  guard let first = chapterNumbers.min(), let last = chapterNumbers.max() else { return emptyVolumePlanRange }
  return VolumePlanRange(planChapterCount: chapterNumbers.count, planFirstChapter: first, planLastChapter: last)
}

struct VolumeOrdinalRow: Equatable, Sendable {
  var volumeKey: String
  var ordinal: Int
  var state: VolumeState
}

// apps/novel-forge-server/src/common/volume-stats.ts:58
func nextVolumeToActivate(_ volumes: [VolumeOrdinalRow], volumeKey: String) -> String? {
  guard let target = volumes.first(where: { $0.volumeKey.jsEquals(volumeKey) }) else { return nil }
  return volumes.filter { $0.ordinal > target.ordinal && $0.state == .notStarted }.jsStableSorted { $0.ordinal < $1.ordinal }.first?.volumeKey
}

// apps/novel-forge-server/src/common/volume-stats.ts:70
func volumeToAutoActivate(_ volumes: [VolumeOrdinalRow]) -> String? {
  if volumes.contains(where: { $0.state == .active }) { return nil }
  let passedOrdinal = volumes.filter { $0.state == .goalMet }.map(\.ordinal).max()
  let candidates = volumes.filter { $0.state == .notStarted && ($0.ordinal > (passedOrdinal ?? Int.min) || passedOrdinal == nil) }
  return candidates.jsStableSorted { $0.ordinal < $1.ordinal }.first?.volumeKey
}
