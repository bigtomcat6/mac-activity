import SwiftUI

/// Test-only adaptive flattening and endpoint derivatives. No newer CGPath API.
struct SmoothPathProbe {
    struct Segment {
        var controls: [CGPoint]
        var start: CGPoint { controls.first! }
        var end: CGPoint { controls.last! }
        var leading: CGPoint { controls.dropFirst().first(where: { $0 != start }) ?? end }
        var trailing: CGPoint { controls.dropLast().reversed().first(where: { $0 != end }) ?? start }
        func flattened(depth: Int = 0) -> [CGPoint] {
            let chord = hypot(end.x - start.x, end.y - start.y)
            let polygon = zip(controls, controls.dropFirst()).reduce(CGFloat(0)) {
                $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
            }
            if controls.count == 2 || depth == 18 || (polygon - chord < chord * 0.00001 && chord < 1) {
                return [start, end]
            }
            var row = controls, left = [start], right = [end]
            while row.count > 1 {
                row = zip(row, row.dropFirst()).map { CGPoint(x: ($0.x + $1.x) / 2, y: ($0.y + $1.y) / 2) }
                left.append(row.first!); right.append(row.last!)
            }
            return Segment(controls: left).flattened(depth: depth + 1).dropLast()
                + Segment(controls: right.reversed()).flattened(depth: depth + 1)
        }
    }
    struct Contour {
        var segments: [Segment]
        var points: [CGPoint] { segments.flatMap { $0.flattened().dropLast() } }
        var hasStationaryCurveEndpoint: Bool {
            segments.contains { $0.controls.count > 2 && ($0.controls[1] == $0.start || $0.controls[$0.controls.count - 2] == $0.end) }
        }
        var maximumJoinAngle: CGFloat {
            zip(segments, segments.dropFirst() + segments.prefix(1)).map {
                Self.angle(CGPoint(x: $0.end.x - $0.trailing.x, y: $0.end.y - $0.trailing.y),
                           CGPoint(x: $1.leading.x - $1.start.x, y: $1.leading.y - $1.start.y))
            }.max() ?? 0
        }
        var maximumFlattenedTurn: CGFloat {
            let p = points
            return p.indices.map { i in
                let a = p[(i + p.count - 1) % p.count], b = p[i], c = p[(i + 1) % p.count]
                return Self.angle(CGPoint(x: b.x - a.x, y: b.y - a.y), CGPoint(x: c.x - b.x, y: c.y - b.y))
            }.max() ?? 0
        }
        var selfIntersects: Bool {
            let p = points
            func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
                (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            }
            for i in p.indices {
                for j in p.indices where j > i + 1 && !(i == 0 && j == p.count - 1) {
                    let a = p[i], b = p[(i + 1) % p.count], c = p[j], d = p[(j + 1) % p.count]
                    if cross(a, b, c) * cross(a, b, d) < 0 && cross(c, d, a) * cross(c, d, b) < 0 { return true }
                }
            }
            return false
        }
        private static func angle(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let lengths = hypot(a.x, a.y) * hypot(b.x, b.y)
            guard lengths > 0 else { return .pi }
            return acos(min(1, max(-1, (a.x * b.x + a.y * b.y) / lengths)))
        }
    }
    var contours: [Contour] = []
    init(_ path: Path) {
        var start = CGPoint.zero, current = CGPoint.zero, segments: [Segment] = []
        func add(_ controls: [CGPoint]) {
            if controls.contains(where: { $0 != current }) { segments.append(Segment(controls: [current] + controls)) }
            current = controls.last!
        }
        path.forEach {
            switch $0 {
            case .move(let p): start = p; current = p; segments = []
            case .line(let p): add([p])
            case .quadCurve(let p, let c): add([c, p])
            case .curve(let p, let c1, let c2): add([c1, c2, p])
            case .closeSubpath: add([start]); contours.append(Contour(segments: segments))
            }
        }
    }
}
