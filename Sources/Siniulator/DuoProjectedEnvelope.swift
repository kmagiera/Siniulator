import SceneKit
import simd

/// Tight silhouette envelopes for the fixed camera. Loading samples the actual
/// skinned vertices; a frame only rotates two small convex hulls and interpolates
/// their extrema. This table affects cropping, never the rendered USD pose.
@MainActor final class DuoProjectedEnvelope {
    @MainActor private struct Mesh {
        let data: DuoMesh
        var selected: [Int]

        init(_ data: DuoMesh) {
            self.data = data
            selected = Array(data.vertices.indices)
        }

        func appendProjected(to points: inout [SIMD2<Float>], center: SIMD3<Float>,
                             direction: SIMD3<Float>, right: SIMD3<Float>, distance: Float, focal: Float) {
            let transforms = data.transforms
            for index in selected {
                let world = data.position(at: index, using: transforms)
                let offset = SIMD3(world.x, world.y, world.z) - center
                let depth = distance - simd_dot(offset, direction)
                points.append(SIMD2(simd_dot(offset, right), -offset.z) * (focal / depth))
            }
        }
    }

    private let hulls: [[SIMD2<Float>]]
    let maximumSpan: CGFloat

    init(meshes: [DuoMesh], center: SIMD3<Float>, radius: Float, apply: (CGFloat) -> Void) {
        var meshes = meshes.map(Mesh.init)
        let halfFOV = Float(DuoStage.halfFieldOfView)
        let fraction = Float(DuoStage.cameraFitFraction)
        let distance = radius / sin(atan(tan(halfFOV) * fraction))
        let focal = 1 / (2 * tan(halfFOV))
        var hulls: [[SIMD2<Float>]] = []
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(meshes.reduce(0) { $0 + $1.data.vertices.count })
        func project(angle: CGFloat) {
            apply(angle)
            let orbit = Float(DuoPose.orbit(at: DuoPose.phase(for: Double(angle))))
            let direction = SIMD3<Float>(sin(orbit), cos(orbit), 0)
            let right = SIMD3<Float>(cos(orbit), -sin(orbit), 0)
            points.removeAll(keepingCapacity: true)
            for mesh in meshes {
                mesh.appendProjected(to: &points, center: center, direction: direction,
                    right: right, distance: distance, focal: focal)
            }
        }
        // Find the actual silhouette vertices over a coarse sweep first. The
        // dense pass need not repeatedly skin/sort tens of thousands of hidden
        // interior vertices. The pixel guard covers changes between samples.
        var candidates = Set<Int>()
        for angle in stride(from: 0, through: 180, by: 5) {
            project(angle: CGFloat(angle))
            candidates.formUnion(Self.convexHullIndices(points))
        }
        var offset = 0
        for index in meshes.indices {
            meshes[index].selected = meshes[index].data.vertices.indices.filter { candidates.contains(offset + $0) }
            offset += meshes[index].data.vertices.count
        }
        for angle in 0...180 {
            project(angle: CGFloat(angle))
            hulls.append(Self.convexHullIndices(points).map { points[$0] })
        }
        self.hulls = hulls
        maximumSpan = CGFloat(2 * (hulls.flatMap { $0 }.map(simd_length).max() ?? 0.5)) + 2 / DuoStage.viewport
    }

    func bounds(angle: CGFloat, quarterTurns: CGFloat, side: CGFloat) -> CGRect? {
        guard !hulls.isEmpty else { return nil }
        let angle = min(180, max(0, angle))
        let sample = angle
        let lower = Int(floor(sample)), upper = min(hulls.count - 1, lower + 1)
        let t = sample - CGFloat(lower)
        let rotation = Float(quarterTurns * .pi / 2), c = cos(rotation), s = sin(rotation)
        func extrema(_ hull: [SIMD2<Float>]) -> SIMD4<Float> {
            var result = SIMD4<Float>(.infinity, .infinity, -.infinity, -.infinity)
            for point in hull {
                let x = point.x * c + point.y * s, y = point.y * c - point.x * s
                result = SIMD4(min(result.x, x), min(result.y, y), max(result.z, x), max(result.w, y))
            }
            return result
        }
        let value = simd_mix(extrema(hulls[lower]), extrema(hulls[upper]), SIMD4(repeating: Float(t)))
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite, value.w.isFinite else { return nil }
        // A one-point guard at the reference scale covers interpolation and
        // antialiasing. It scales with the hardware, not with the window crop.
        let guardBand = side / DuoStage.viewport
        return CGRect(x: side * (0.5 + CGFloat(value.x)), y: side * (0.5 + CGFloat(value.y)),
            width: side * CGFloat(value.z - value.x), height: side * CGFloat(value.w - value.y))
            .insetBy(dx: -guardBand, dy: -guardBand)
    }

    /// The visible rounded corners are known before SceneKit's first draw.
    /// Do not ray-test the renderer's asynchronously updated skinned mesh to
    /// install mouse/cursor targets for the current authored pose.
    func corners(angle: CGFloat, quarterTurns: CGFloat, side: CGFloat) -> [DeviceResizeCorner: CGPoint]? {
        guard let bounds = bounds(angle: angle, quarterTurns: quarterTurns, side: side) else { return nil }
        let sample = min(180, max(0, angle)), lower = Int(floor(sample))
        let upper = min(hulls.count - 1, lower + 1), t = sample - CGFloat(lower)
        let rotation = Float(quarterTurns * .pi / 2), c = cos(rotation), s = sin(rotation)
        func points(_ hull: [SIMD2<Float>]) -> [CGPoint] {
            hull.map { CGPoint(x: side * (0.5 + CGFloat($0.x * c + $0.y * s)),
                y: side * (0.5 + CGFloat($0.y * c - $0.x * s))) }
        }
        let a = points(hulls[lower]), b = points(hulls[upper])
        func nearest(to target: CGPoint, on hull: [CGPoint]) -> CGPoint {
            var best = hull[0], distance = CGFloat.infinity
            for index in hull.indices {
                let p = hull[index], q = hull[(index + 1) % hull.count]
                let dx = q.x - p.x, dy = q.y - p.y, length = dx * dx + dy * dy
                let fraction = length > 0 ? min(1, max(0,
                    ((target.x - p.x) * dx + (target.y - p.y) * dy) / length)) : 0
                let point = CGPoint(x: p.x + fraction * dx, y: p.y + fraction * dy)
                let d = hypot(point.x - target.x, point.y - target.y)
                if d < distance { best = point; distance = d }
            }
            return best
        }
        return Dictionary(uniqueKeysWithValues: DeviceResizeCorner.allCases.map { corner in
            let vertex = CGPoint(x: corner.isLeft ? bounds.minX : bounds.maxX,
                y: corner.isTop ? bounds.maxY : bounds.minY)
            let p = nearest(to: vertex, on: a), q = nearest(to: vertex, on: b)
            return (corner, CGPoint(x: p.x + t * (q.x - p.x), y: p.y + t * (q.y - p.y)))
        })
    }

    func distanceToOutline(at point: CGPoint, angle: CGFloat, quarterTurns: CGFloat, side: CGFloat) -> CGFloat? {
        guard !hulls.isEmpty, side > 0 else { return nil }
        let sample = min(180, max(0, angle)), lower = Int(floor(sample))
        let upper = min(hulls.count - 1, lower + 1), t = Float(sample - CGFloat(lower))
        let rotation = Float(quarterTurns * .pi / 2), c = cos(rotation), s = sin(rotation)
        let p = SIMD2(Float(point.x / side - 0.5), Float(point.y / side - 0.5))
        let target = SIMD2(p.x * c - p.y * s, p.x * s + p.y * c)
        func distance(_ hull: [SIMD2<Float>]) -> Float {
            var result = Float.infinity
            for index in hull.indices {
                let a = hull[index], ab = hull[(index + 1) % hull.count] - a
                let length = simd_length_squared(ab)
                let fraction = length > 0 ? min(1, max(0, simd_dot(target - a, ab) / length)) : 0
                result = min(result, simd_length(target - a - fraction * ab))
            }
            return result
        }
        return side * CGFloat((1 - t) * distance(hulls[lower]) + t * distance(hulls[upper]))
    }

    private static func convexHullIndices(_ points: [SIMD2<Float>]) -> [Int] {
        let sorted = points.indices.sorted { points[$0].x == points[$1].x ? points[$0].y < points[$1].y : points[$0].x < points[$1].x }
        guard sorted.count > 2 else { return sorted }
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
            let ab = b - a, ac = c - a
            return ab.x * ac.y - ab.y * ac.x
        }
        var lower: [Int] = [], upper: [Int] = []
        for point in sorted {
            while lower.count >= 2, cross(points[lower[lower.count - 2]], points[lower[lower.count - 1]], points[point]) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        for point in sorted.reversed() {
            while upper.count >= 2, cross(points[upper[upper.count - 2]], points[upper[upper.count - 1]], points[point]) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        lower.removeLast(); upper.removeLast()
        return lower + upper
    }
}
