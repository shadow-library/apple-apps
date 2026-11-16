import Foundation

struct VolumeStanding: Equatable, Sendable {
  let volume: String
  let ordinal: Int
  let state: VolumeState
}

// apps/novel-forge-server/src/common/volume-stats.ts:70 ranks by ordinal alone, so a volume tied with a goal-met one is never activated; here the key breaks the tie, compared by UTF-16 code units as JavaScript does
func volumeStandings(of volumes: [VolumeRecord]) -> [VolumeStanding] {
  let ordered = volumes.sorted { ($0.ordinal, JSString($0.volume)) < ($1.ordinal, JSString($1.volume)) }
  let passed = ordered.lastIndex { $0.goalMet }.map { $0 + 1 } ?? 0
  let active = ordered[passed...].firstIndex { !$0.goalMet }
  return ordered.enumerated().map { index, volume in
    VolumeStanding(volume: volume.volume, ordinal: volume.ordinal, state: volume.goalMet ? .goalMet : index == active ? .active : .notStarted)
  }
}

func activeVolume(of volumes: [VolumeRecord]) -> String? {
  volumeStandings(of: volumes).first { $0.state == .active }?.volume
}
