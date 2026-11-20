/// Reciprocal rank fusion (Cormack, Clarke and Büttcher, 2009): an item scores the sum of 1 / (k + rank) over the lists it appears in, rank counted from 1.
/// It needs no calibration between BM25 and cosine scores, and k = 60, the value the paper found robust, keeps one list's first place from outweighing an
/// item both lists rank well.
enum RetrievalFusion {
  static let k = 60.0

  /// Both lists best first, each item at most once in each. Ties go to the better lexical rank, so a literal match wins; that orders every tie, since two
  /// items of equal score never share a lexical rank.
  static func fuse<Item>(lexical: [Item], semantic: [Item], id: (Item) -> Int64, limit: Int) -> [(item: Item, score: Double)] {
    var fused: [Int64: (item: Item, score: Double, lexicalRank: Int)] = [:]
    for (rank, item) in lexical.enumerated() {
      fused[id(item)] = (item, 1 / (k + Double(rank + 1)), rank)
    }
    for (rank, item) in semantic.enumerated() {
      let share = 1 / (k + Double(rank + 1))
      if let entry = fused[id(item)] {
        fused[id(item)] = (entry.item, entry.score + share, entry.lexicalRank)
      } else {
        fused[id(item)] = (item, share, Int.max)
      }
    }
    let ranked = fused.values.sorted { first, second in
      first.score != second.score ? first.score > second.score : first.lexicalRank < second.lexicalRank
    }
    return ranked.prefix(max(limit, 0)).map { ($0.item, $0.score) }
  }
}
