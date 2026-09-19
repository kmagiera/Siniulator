import SceneKit
import XCTest
@testable import Siniulator

final class DuoScreenHitMeshTests: XCTestCase {
    @MainActor private func quad(interleaved: Bool = false, invalidIndex: Bool = false) -> SCNGeometry {
        let positions = SCNGeometrySource(vertices: [SCNVector3(0,0,0), SCNVector3(1,0,0),
            SCNVector3(1,1,0), SCNVector3(0,1,0)])
        // Deliberately use a different UV index order, as imported USD does.
        let uv = SCNGeometrySource(textureCoordinates: [CGPoint(x: 1,y: 1), CGPoint(x: 0,y: 1),
            CGPoint(x: 0,y: 0), CGPoint(x: 1,y: 0)])
        var indices: [UInt32] = interleaved ? [4, 0,2, 1,3, 2,0, 3,1] : [4, 0,1,2,3, 2,3,0,1]
        if invalidIndex { indices[1] = 99 }
        let element = SCNGeometryElement(data: indices.withUnsafeBytes { Data($0) },
            primitiveType: .polygon, primitiveCount: 1, indicesChannelCount: 2,
            interleavedIndicesChannels: interleaved, bytesPerIndex: 4)
        return SCNGeometry(sources: [positions, uv], elements: [element], sourceChannels: [0,1])
    }

    @MainActor func testPolygonCoverageAndIndependentUVIndices() throws {
        for interleaved in [false, true] {
            let mesh = try XCTUnwrap(DuoScreenHitMesh(node: SCNNode(geometry: quad(interleaved: interleaved))))
            for x in [0.1, 0.5, 0.9] { for y in [0.1, 0.5, 0.9] {
                // Cover both fan triangles, their shared seam and both windings.
                for side in [-1.0, 1.0] {
                    let uv = try XCTUnwrap(mesh.textureCoordinate(from: SCNVector3(x,y,side), to: SCNVector3(x,y,-side)))
                    XCTAssertEqual(uv.x, x, accuracy: 0.0001)
                    XCTAssertEqual(uv.y, y, accuracy: 0.0001)
                }
            } }
            XCTAssertNil(mesh.textureCoordinate(from: SCNVector3(2,0.5,1), to: SCNVector3(2,0.5,-1)))
            XCTAssertNil(mesh.textureCoordinate(from: SCNVector3(0.5,0.5,1), to: SCNVector3(0.5,0.5,0.1)))
        }
    }

    @MainActor func testSkinningUsesPresentedBoneAndRefreshesCachedPose() throws {
        let geometry = quad()
        let node = SCNNode(geometry: geometry)
        let bone = SCNNode()
        let weights: [Float] = [1,1,1,1]
        let indices: [UInt16] = [0,0,0,0]
        node.skinner = SCNSkinner(baseGeometry: geometry, bones: [bone],
            boneInverseBindTransforms: [NSValue(scnMatrix4: SCNMatrix4Identity)],
            boneWeights: SCNGeometrySource(data: weights.withUnsafeBytes { Data($0) }, semantic: .boneWeights,
                vectorCount: 4, usesFloatComponents: true, componentsPerVector: 1,
                bytesPerComponent: 4, dataOffset: 0, dataStride: 4),
            boneIndices: SCNGeometrySource(data: indices.withUnsafeBytes { Data($0) }, semantic: .boneIndices,
                vectorCount: 4, usesFloatComponents: false, componentsPerVector: 1,
                bytesPerComponent: 2, dataOffset: 0, dataStride: 2))
        let mesh = try XCTUnwrap(DuoScreenHitMesh(node: node))
        for translation in [0.0, 3.0, -2.0, 0.0] {
            bone.position = SCNVector3(translation,0,0)
            SCNTransaction.flush()
            let uv = try XCTUnwrap(mesh.textureCoordinate(from: SCNVector3(translation+0.3,0.7,1),
                to: SCNVector3(translation+0.3,0.7,-1)))
            XCTAssertEqual(uv.x, 0.3, accuracy: 0.0001)
            XCTAssertEqual(uv.y, 0.7, accuracy: 0.0001)
            let projected = try XCTUnwrap(mesh.position(at: uv))
            XCTAssertEqual(CGFloat(projected.x), translation + 0.3, accuracy: 0.0001)
            XCTAssertEqual(CGFloat(projected.y), 0.7, accuracy: 0.0001)
            let edge = try XCTUnwrap(mesh.nearestTextureCoordinate(to: CGPoint(x: translation + 2, y: 0.7),
                project: { $0 }, unproject: { $0 }))
            XCTAssertEqual(edge.x, 1, accuracy: 0.0001)
            XCTAssertEqual(edge.y, 0.7, accuracy: 0.0001)
        }
    }

    @MainActor func testUnknownOrInvalidGeometryIsRejected() {
        XCTAssertNil(DuoScreenHitMesh(node: SCNNode()))
        XCTAssertNil(DuoScreenHitMesh(node: SCNNode(geometry: quad(invalidIndex: true))))
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: [SCNVector3(0,0,0)])], elements: [])
        XCTAssertNil(DuoScreenHitMesh(node: SCNNode(geometry: geometry)))
    }

    @MainActor func testProjectionClampsToMeshEdgesAndInvertsTextureCoordinates() throws {
        let mesh = try XCTUnwrap(DuoScreenHitMesh(node: SCNNode(geometry: quad())))
        for x in [-2.0, 0.3, 2.0] { for y in [-2.0, 0.7, 2.0] {
            let expected = CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
            let world = try XCTUnwrap(mesh.position(at: CGPoint(x: x, y: y)))
            XCTAssertEqual(CGFloat(world.x), expected.x, accuracy: 0.0001)
            XCTAssertEqual(CGFloat(world.y), expected.y, accuracy: 0.0001)
            if x < 0 || x > 1 || y < 0 || y > 1 {
                let boundary = try XCTUnwrap(mesh.nearestTextureCoordinate(to: CGPoint(x: x, y: y),
                    project: { $0 }, unproject: { $0 }))
                XCTAssertEqual(boundary.x, expected.x, accuracy: 0.0001)
                XCTAssertEqual(boundary.y, expected.y, accuracy: 0.0001)
            }
        } }
    }
}
