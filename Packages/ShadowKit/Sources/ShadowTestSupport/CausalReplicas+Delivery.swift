import Foundation
import ShadowStore

extension CausalReplicas {
  public func deliverable(from writer: Int, to reader: Int) -> Int {
    precondition(writer != reader, "a replica never receives its own changes")
    let stream = streams[writer]
    let taken = applied[reader][writer]
    guard order == .causal else { return stream.count - taken }
    var available = 0
    for change in stream[taken...] {
      guard satisfied(change.dependencies, writer: writer, reader: reader) else { break }
      available += 1
    }
    return available
  }

  @discardableResult
  public func deliver(from writer: Int, to reader: Int, atMost limit: Int = .max, batch: Int = .max) async throws -> Int {
    let total = min(deliverable(from: writer, to: reader), max(limit, 0))
    guard total > 0 else { return 0 }
    let first = applied[reader][writer]
    try await apply(streams[writer][first..<(first + total)], writer: writer, reader: reader, batch: batch)
    applied[reader][writer] = first + total
    log.append(CausalReplicaDelivery(writer: writer, reader: reader, first: first, count: total, isRedelivery: false))
    return total
  }

  public func redeliver(from writer: Int, to reader: Int, count: Int) async throws {
    precondition(writer != reader, "a replica never receives its own changes")
    let taken = applied[reader][writer]
    let amount = min(max(count, 0), taken)
    guard amount > 0 else { return }
    try await apply(streams[writer][(taken - amount)..<taken], writer: writer, reader: reader, batch: .max)
    log.append(CausalReplicaDelivery(writer: writer, reader: reader, first: taken - amount, count: amount, isRedelivery: true))
  }

  public func step(using generator: inout SeededGenerator) async throws -> Bool {
    var options = [(writer: Int, reader: Int, available: Int)]()
    for reader in 0..<count {
      for writer in 0..<count where writer != reader {
        let available = deliverable(from: writer, to: reader)
        if available > 0 { options.append((writer, reader, available)) }
      }
    }
    guard !options.isEmpty else { return false }
    let redeliverable = options.filter { applied[$0.reader][$0.writer] > 0 }
    if !redeliverable.isEmpty, generator.chance(0.15) {
      let pick = generator.pick(from: redeliverable)
      try await redeliver(from: pick.writer, to: pick.reader, count: generator.int(in: 1...min(applied[pick.reader][pick.writer], 4)))
      return true
    }
    let pick = generator.pick(from: options)
    let amount = generator.int(in: 1...pick.available)
    try await deliver(from: pick.writer, to: pick.reader, atMost: amount, batch: generator.int(in: 1...amount))
    return true
  }

  public func settle() async throws {
    var progressed = true
    while progressed {
      progressed = false
      for reader in 0..<count {
        for writer in 0..<count where writer != reader {
          if try await deliver(from: writer, to: reader) > 0 { progressed = true }
        }
      }
    }
  }

  private func satisfied(_ dependencies: [Int], writer: Int, reader: Int) -> Bool {
    for other in 0..<count where other != writer && other != reader {
      if applied[reader][other] < dependencies[other] { return false }
    }
    return true
  }

  private func apply(_ changes: ArraySlice<CausalReplicaChange>, writer: Int, reader: Int, batch: Int) async throws {
    let lines = changes.map(\.line)
    let size = max(batch, 1)
    var start = 0
    while start < lines.count {
      let end = start.addingReportingOverflow(size).overflow ? lines.count : min(start + size, lines.count)
      _ = try await stores[reader].applyRemote(Array(lines[start..<end]))
      start = end
    }
  }
}
