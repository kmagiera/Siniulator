import SceneKit
import XCTest
@testable import Siniulator

final class DuoMeshTests: XCTestCase {
    @MainActor private func node(weights: [Float] = [1, 1, 1, 1], indices: [UInt16] = [0, 0, 0, 0],
                                 bones: [SCNNode] = [SCNNode()]) -> SCNNode {
        let geometry = SCNGeometry(sources: [
            SCNGeometrySource(vertices: [SCNVector3(0, 0, 0), SCNVector3(1, 0, 0),
                SCNVector3(1, 1, 0), SCNVector3(0, 1, 0)]),
            SCNGeometrySource(textureCoordinates: [.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])
        ], elements: [SCNGeometryElement(indices: [UInt16(0), 1, 2, 0, 2, 3], primitiveType: .triangles)])
        let node = SCNNode(geometry: geometry)
        let count = weights.count / 4
        node.skinner = SCNSkinner(baseGeometry: geometry, bones: bones,
            boneInverseBindTransforms: bones.map { _ in NSValue(scnMatrix4: SCNMatrix4Identity) },
            boneWeights: SCNGeometrySource(data: weights.withUnsafeBytes { Data($0) }, semantic: .boneWeights,
                vectorCount: 4, usesFloatComponents: true, componentsPerVector: count,
                bytesPerComponent: 4, dataOffset: 0, dataStride: 4 * count),
            boneIndices: SCNGeometrySource(data: indices.withUnsafeBytes { Data($0) }, semantic: .boneIndices,
                vectorCount: 4, usesFloatComponents: false, componentsPerVector: count,
                bytesPerComponent: 2, dataOffset: 0, dataStride: 2 * count))
        return node
    }

    @MainActor func testRigidAndBlendedPositionsShareLogicalTransforms() throws {
        let a = SCNNode(), b = SCNNode()
        a.position = SCNVector3(2, 0, 0)
        b.position = SCNVector3(6, 0, 0)
        let node = node(weights: Array(repeating: [Float(0.25), 0.75], count: 4).flatMap { $0 },
            indices: Array(repeating: [UInt16(0), 1], count: 4).flatMap { $0 }, bones: [a, b])
        let mesh = try XCTUnwrap(DuoMesh(node: node))
        XCTAssertEqual(mesh.position(at: 0, using: mesh.transforms), SIMD4<Float>(5, 0, 0, 1))
        let hit = try XCTUnwrap(DuoScreenHitMesh(node: node))
        let uv = try XCTUnwrap(hit.textureCoordinate(from: SCNVector3(5.3, 0.7, 1), to: SCNVector3(5.3, 0.7, -1)))
        XCTAssertEqual(uv.x, 0.3, accuracy: 0.0001)
        XCTAssertEqual(uv.y, 0.7, accuracy: 0.0001)
        node.skinner = nil
        node.position = SCNVector3(3, 4, 5)
        let rigid = try XCTUnwrap(DuoMesh(node: node))
        XCTAssertEqual(rigid.position(at: 0, using: rigid.transforms), SIMD4<Float>(3, 4, 5, 1))
    }

    @MainActor func testInvalidSkinningIsRejectedBySweepAndHitTesting() {
        // SceneKit replaces a one-bone skinner's buffers with a rigid binding.
        // Use two influences so the imported weight/index buffers survive.
        let indices = Array(repeating: [UInt16(0), UInt16(1)], count: 4).flatMap { $0 }
        var badIndices = indices
        badIndices[0] = .max
        let badIndex = node(weights: Array(repeating: 0.5, count: 8), indices: badIndices, bones: [SCNNode(), SCNNode()])
        // SceneKit sanitizes negative weights to zero before we can read them.
        let badWeights = [Float.nan, .infinity].map { value in
            (String(describing: value), node(weights: [value, 0.5] + Array(repeating: 0.5, count: 6),
                indices: indices, bones: [SCNNode(), SCNNode()]))
        }
        let zeroWeights = node(weights: Array(repeating: 0, count: 8), indices: indices, bones: [SCNNode(), SCNNode()])
        for (label, invalid) in [("index", badIndex), ("zero weights", zeroWeights)] + badWeights {
            XCTAssertNil(DuoMesh(node: invalid), label)
            XCTAssertNil(DuoPoseClip(root: invalid), "Validate before sweeping or sampling bone indices")
            XCTAssertNil(DuoScreenHitMesh(node: invalid), label)
        }
    }

    @MainActor func testAStaticMeshCannotPopulateTheAnimatedAssetCache() throws {
        let node = node()
        XCTAssertNotNil(DuoMesh(node: node))
        XCTAssertNil(DuoPoseClip(root: node), "An unsupported model without joint tracks must fall back")
    }

    @MainActor func testTruncatedBuffersAndNonfinitePositionsAreRejected() {
        let values: [Float] = [0, 1, 2]
        let truncated = SCNGeometrySource(data: values.withUnsafeBytes { Data($0) }, semantic: .vertex,
            vectorCount: 2, usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        XCTAssertNil(DuoMesh.components(truncated))
        for value in [Float.nan, .infinity] {
            let source = SCNGeometrySource(vertices: [SCNVector3(value, 0, 0)])
            let node = SCNNode(geometry: SCNGeometry(sources: [source], elements: []))
            XCTAssertNil(DuoMesh(node: node))
            XCTAssertNil(DuoPoseClip(root: node))
        }
    }
}
