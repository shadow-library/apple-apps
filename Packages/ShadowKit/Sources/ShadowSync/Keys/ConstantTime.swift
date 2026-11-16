import Foundation

func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
  guard lhs.count == rhs.count else { return false }
  return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
