import SwiftUI

nonisolated public enum ShadowSparklineGeometry {
  public static func normalized(_ values: [Double]) -> [Double] {
    let finite = values.filter(\.isFinite)
    guard let low = finite.min(), let high = finite.max() else { return [] }
    guard high > low else { return finite.map { _ in 0.5 } }
    return finite.map { ($0 - low) / (high - low) }
  }
}

public struct ShadowSparkline: View {
  private let values: [Double]

  public init(_ values: [Double]) {
    self.values = values
  }

  public var body: some View {
    SparklineShape(points: ShadowSparklineGeometry.normalized(values))
      .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
      .frame(height: Spacing.space6)
      .accessibilityHidden(true)
  }
}

nonisolated private struct SparklineShape: Shape {
  let points: [Double]

  func path(in rect: CGRect) -> Path {
    var path = Path()
    guard points.count > 1 else { return path }
    let step = rect.width / CGFloat(points.count - 1)
    for (index, point) in points.enumerated() {
      let position = CGPoint(x: rect.minX + step * CGFloat(index), y: rect.maxY - rect.height * CGFloat(point))
      if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
    }
    return path
  }
}
