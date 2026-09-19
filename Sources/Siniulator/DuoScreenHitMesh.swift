import SceneKit
import simd

/// SceneKit's hit test for the imported skinner does not follow its rendered
/// display reliably. Intersect its presented triangles, retaining the model's
/// independent position/UV indices rather than an approximate screen rectangle.
@MainActor final class DuoScreenHitMesh {
    private let source: SCNNode
    private let vertices: [SIMD4<Float>]
    private let influences: [[(index: Int, weight: Float)]]
    private let inverseBinds: [simd_float4x4]
    private let bind: simd_float4x4
    private struct Triangle { let positions: SIMD3<Int>; let uv: [SIMD2<Float>] }
    private let triangles: [Triangle]
    private var posed: [SIMD3<Float>] = []
    private var lastTransforms: [simd_float4x4] = []

    init?(node: SCNNode) {
        guard let geometry = node.geometry,
              let positions = geometry.sources(for: .vertex).first,
              let values = Self.components(positions), positions.componentsPerVector == 3 else { return nil }
        source = node
        guard let triangles = Self.triangles(geometry) else { return nil }
        self.triangles = triangles
        vertices = stride(from: 0, to: values.count, by: 3).map {
            SIMD4(Float(values[$0]), Float(values[$0 + 1]), Float(values[$0 + 2]), 1)
        }
        if let skin = node.skinner {
            bind = simd_float4x4(skin.baseGeometryBindTransform)
            inverseBinds = skin.boneInverseBindTransforms?.map { simd_float4x4($0.scnMatrix4Value) }
                ?? Array(repeating: matrix_identity_float4x4, count: skin.bones.count)
            guard inverseBinds.count == skin.bones.count else { return nil }
            let weights: SCNGeometrySource? = skin.boneWeights
            let indices: SCNGeometrySource? = skin.boneIndices
            if let weights, let indices, weights.vectorCount > 0 {
                guard weights.vectorCount == vertices.count, indices.vectorCount == vertices.count,
                      weights.componentsPerVector == indices.componentsPerVector,
                      let w = Self.components(weights), let b = Self.components(indices),
                      b.allSatisfy({ $0 >= 0 && $0 < Double(skin.bones.count) && $0.rounded() == $0 })
                else { return nil }
                let count = weights.componentsPerVector
                influences = vertices.indices.map { vertex in
                    (0..<count).map { (Int(b[vertex * count + $0]), Float(w[vertex * count + $0])) }
                }
            } else {
                // The rigid cover uses a one-bone skinner without weight data.
                guard skin.bones.count == 1 else { return nil }
                influences = vertices.map { _ in [(0, 1)] }
            }
        } else {
            bind = matrix_identity_float4x4
            inverseBinds = []
            influences = []
        }
    }

    private func updatePose() {
        let transforms: [simd_float4x4]
        if let skin = source.skinner {
            transforms = skin.bones.enumerated().map { index, bone in
                bone.presentation.simdWorldTransform * inverseBinds[index] * bind
            }
        } else {
            transforms = [source.presentation.simdWorldTransform]
        }
        if transforms != lastTransforms {
            posed = vertices.enumerated().map { index, vertex -> SIMD3<Float> in
                let point: SIMD4<Float>
                if influences.isEmpty { point = transforms[0] * vertex }
                else {
                    point = influences[index].reduce(SIMD4<Float>.zero) {
                        $0 + (transforms[$1.index] * vertex) * $1.weight
                    }
                }
                return SIMD3(point.x, point.y, point.z)
            }
            lastTransforms = transforms
        }
    }

    func textureCoordinate(from near: SCNVector3, to far: SCNVector3) -> CGPoint? {
        updatePose()
        let origin = SIMD3<Float>(Float(near.x), Float(near.y), Float(near.z))
        let direction = SIMD3<Float>(Float(far.x), Float(far.y), Float(far.z)) - origin
        var closest: Float = 1
        var result: SIMD2<Float>?
        // Two-sided Möller–Trumbore intersection. The imported inner screen
        // has mixed winding, just like the double-sided rendered material.
        for triangle in triangles {
            let a = posed[triangle.positions.x]
            let ab = posed[triangle.positions.y] - a, ac = posed[triangle.positions.z] - a
            let p = simd_cross(direction, ac), determinant = simd_dot(ab, p)
            guard abs(determinant) > 1e-8 else { continue }
            let offset = origin - a
            let u = simd_dot(offset, p) / determinant
            guard u >= -1e-5, u <= 1.00001 else { continue }
            let q = simd_cross(offset, ab)
            let v = simd_dot(direction, q) / determinant
            guard v >= -1e-5, u + v <= 1.00001 else { continue }
            let distance = simd_dot(ac, q) / determinant
            guard distance >= 0, distance <= closest else { continue }
            closest = distance
            result = triangle.uv[0] * (1 - u - v) + triangle.uv[1] * u + triangle.uv[2] * v
        }
        return result.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
    }

    /// UV of the closest point on the projected mesh, after a drag misses it.
    /// Looking at every triangle edge also covers rounded corners and cutouts.
    func nearestTextureCoordinate(to point: CGPoint, project: (SCNVector3) -> SCNVector3,
                                  unproject: (SCNVector3) -> SCNVector3) -> CGPoint? {
        updatePose()
        let projected = posed.map { position -> SIMD3<Float> in
            let p = project(SCNVector3(position.x, position.y, position.z))
            return SIMD3(Float(p.x), Float(p.y), Float(p.z))
        }
        let target = SIMD2<Float>(Float(point.x), Float(point.y))
        var distance = Float.infinity
        var best: SIMD2<Float>?
        for triangle in triangles {
            for edge in 0..<3 {
                let next = (edge + 1) % 3
                let a = projected[triangle.positions[edge]]
                let b = projected[triangle.positions[next]]
                let t = Self.segmentFraction(target, SIMD2(a.x, a.y), SIMD2(b.x, b.y))
                let candidate = a + (b - a) * t
                let squared = simd_length_squared(SIMD2(candidate.x, candidate.y) - target)
                if squared < distance {
                    // Window-space depth interpolates linearly, but UVs do
                    // not under perspective. Unproject to recover the actual
                    // edge fraction without a numerically fragile edge hit.
                    let p = unproject(SCNVector3(candidate.x, candidate.y, candidate.z))
                    let start = posed[triangle.positions[edge]], end = posed[triangle.positions[next]]
                    let length = simd_length_squared(end - start)
                    let fraction = length > 1e-12
                        ? min(1, max(0, simd_dot(SIMD3(Float(p.x), Float(p.y), Float(p.z)) - start, end - start) / length)) : 0
                    best = triangle.uv[edge] * (1 - fraction) + triangle.uv[next] * fraction
                    distance = squared
                }
            }
        }
        return best.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
    }

    /// Reverse UV mapping for the two-finger overlay. UVs in rounded-off
    /// corners snap to the actual mesh boundary, not an imaginary rectangle.
    func position(at uv: CGPoint) -> SCNVector3? {
        updatePose()
        let target = SIMD2<Float>(Float(uv.x), Float(uv.y))
        var distance = Float.infinity
        var best: SIMD3<Float>?
        func world(_ p: SIMD3<Float>) -> SCNVector3 { SCNVector3(p.x, p.y, p.z) }
        for triangle in triangles {
            let a = triangle.uv[0], ab = triangle.uv[1] - a, ac = triangle.uv[2] - a
            let offset = target - a
            let determinant = ab.x * ac.y - ab.y * ac.x
            if abs(determinant) > 1e-10 {
                let u = (offset.x * ac.y - offset.y * ac.x) / determinant
                let v = (ab.x * offset.y - ab.y * offset.x) / determinant
                if u >= -1e-5, v >= -1e-5, u + v <= 1.00001 {
                    return world(posed[triangle.positions.x] * (1 - u - v)
                        + posed[triangle.positions.y] * u + posed[triangle.positions.z] * v)
                }
            }
            for edge in 0..<3 {
                let next = (edge + 1) % 3
                let a = triangle.uv[edge], b = triangle.uv[next]
                let t = Self.segmentFraction(target, a, b)
                let squared = simd_length_squared(a + (b - a) * t - target)
                if squared < distance {
                    distance = squared
                    best = posed[triangle.positions[edge]] * (1 - t) + posed[triangle.positions[next]] * t
                }
            }
        }
        return best.map(world)
    }

    private static func segmentFraction(_ point: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let length = simd_length_squared(b - a)
        return length > 1e-12 ? min(1, max(0, simd_dot(point - a, b - a) / length)) : 0
    }

    private static func triangles(_ geometry: SCNGeometry) -> [Triangle]? {
        guard let positionSource = geometry.sources.firstIndex(where: { $0.semantic == .vertex }),
              let uvSource = geometry.sources.firstIndex(where: { $0.semantic == .texcoord }),
              let uvValues = components(geometry.sources[uvSource]),
              geometry.sources[uvSource].componentsPerVector == 2 else { return nil }
        let uv = stride(from: 0, to: uvValues.count, by: 2).map {
            SIMD2<Float>(Float(uvValues[$0]), Float(uvValues[$0 + 1]))
        }
        let channels = geometry.geometrySourceChannels?.map(\.intValue)
            ?? Array(repeating: 0, count: geometry.sources.count)
        guard channels.count == geometry.sources.count else { return nil }
        var result: [Triangle] = []
        for element in geometry.elements {
            guard element.primitiveType == .triangles || element.primitiveType == .polygon,
                  element.indicesChannelCount > 0,
                  channels.allSatisfy({ $0 >= 0 && $0 < element.indicesChannelCount }),
                  [1, 2, 4].contains(element.bytesPerIndex) else { return nil }
            let indices: [Int] = element.data.withUnsafeBytes { bytes in
                stride(from: 0, to: bytes.count - element.bytesPerIndex + 1, by: element.bytesPerIndex).map { offset in
                    switch element.bytesPerIndex {
                    case 1: Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                    case 2: Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                    default: Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                    }
                }
            }
            let header = element.primitiveType == .polygon ? element.primitiveCount : 0
            guard indices.count >= header else { return nil }
            let counts = header > 0 ? Array(indices.prefix(header)) : Array(repeating: 3, count: element.primitiveCount)
            let count = counts.reduce(0, +)
            guard counts.allSatisfy({ $0 >= 3 }),
                  indices.count == header + count * element.indicesChannelCount else { return nil }
            func index(_ corner: Int, _ source: Int) -> Int {
                indices[header + (element.hasInterleavedIndicesChannels
                    ? corner * element.indicesChannelCount + channels[source]
                    : channels[source] * count + corner)]
            }
            var start = 0
            for corners in counts {
                // Imported display polygons are convex; fan triangulation also
                // preserves the narrow authored strips through the hinge.
                for corner in 1..<(corners - 1) {
                    let corners = [start, start + corner, start + corner + 1]
                    let positions = corners.map { index($0, positionSource) }
                    let texcoords = corners.map { index($0, uvSource) }
                    guard positions.allSatisfy({ $0 < geometry.sources[positionSource].vectorCount }),
                          texcoords.allSatisfy({ $0 < uv.count }) else { return nil }
                    result.append(Triangle(positions: SIMD3(positions), uv: texcoords.map { uv[$0] }))
                }
                start += corners
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Validate imported buffers before reading them; an unfamiliar local SDK
    /// model must fail closed, not perform an out-of-bounds or unaligned load.
    private static func components(_ source: SCNGeometrySource) -> [Double]? {
        let size = source.bytesPerComponent
        guard source.vectorCount > 0, source.componentsPerVector > 0,
              source.dataOffset >= 0, source.dataStride >= source.componentsPerVector * size,
              [1, 2, 4, 8].contains(size),
              !source.usesFloatComponents || [4, 8].contains(size),
              source.dataOffset + (source.vectorCount - 1) * source.dataStride
                + source.componentsPerVector * size <= source.data.count else { return nil }
        return source.data.withUnsafeBytes { data in
            (0..<source.vectorCount).flatMap { vector in
                (0..<source.componentsPerVector).map { component -> Double in
                    let offset = source.dataOffset + vector * source.dataStride + component * size
                    if source.usesFloatComponents {
                        return size == 4 ? Double(data.loadUnaligned(fromByteOffset: offset, as: Float.self))
                            : data.loadUnaligned(fromByteOffset: offset, as: Double.self)
                    }
                    switch size {
                    case 1: return Double(data.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                    case 2: return Double(data.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                    case 4: return Double(data.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                    default: return Double(data.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                    }
                }
            }
        }
    }
}
