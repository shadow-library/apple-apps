import Foundation
import NovelForgeCore

nonisolated struct VolumeSummary: Sendable, Equatable {
  let key: String
  let ordinal: Int
  let title: String?
  let objective: String?
  let state: VolumeState
  let planFirst: Int?
  let planLast: Int?
}

nonisolated struct ChapterGroup: Equatable {
  let key: String
  let number: Int?
  let volume: VolumeSummary?
  var chapters: [Int]
}

nonisolated enum ChapterGrouping {
  static let ungroupedKey = "all"

  // platform/apps/novel-forge-web/src/lib/chapter-list.ts:groupChaptersByVolume
  static func group(volumes: [VolumeSummary], chapters: [Int]) -> [ChapterGroup] {
    let sorted = chapters.sorted()
    var groups = volumes.sorted { $0.ordinal < $1.ordinal }.enumerated().map { ChapterGroup(key: $1.key, number: $0 + 1, volume: $1, chapters: []) }
    guard !groups.isEmpty else { return [ChapterGroup(key: ungroupedKey, number: nil, volume: nil, chapters: sorted)] }
    let ranged = groups.indices.filter { groups[$0].volume?.planFirst != nil }
    let highest = ranged.compactMap { groups[$0].volume?.planLast }.max() ?? 0
    let writing = groups.firstIndex { $0.volume?.state == .active } ?? ranged.last ?? groups.startIndex
    for chapter in sorted {
      let inside = ranged.first { index in
        guard let volume = groups[index].volume else { return false }
        return chapter >= (volume.planFirst ?? 0) && chapter <= (volume.planLast ?? 0)
      }
      let before = ranged.reversed().first { (groups[$0].volume?.planFirst ?? 0) <= chapter }
      let target = inside ?? (chapter > highest ? writing : (before ?? ranged.first ?? writing))
      groups[target].chapters.append(chapter)
    }
    return groups
  }
}
