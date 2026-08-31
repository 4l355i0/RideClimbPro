import Foundation
import SceneKit
import UIKit

struct Climb3DVertex {
    let x: Float
    let y: Float
    let z: Float
}

struct Climb3DTriangle {
    let a: Int32
    let b: Int32
    let c: Int32
}

struct Climb3DMesh {
    // Closed solid retained for optional STL export.
    let vertices: [Climb3DVertex]
    let triangles: [Climb3DTriangle]

    // One-to-one with RideClimbPRO GPXRoute.points.
    let centerline: [Climb3DVertex]

    // Continuous visual road: left/right shared vertices for every prepared path point.
    let visualVertices: [Climb3DVertex]

    // RideClimbPRO terrain grade for each visual segment.
    let visualSegmentGrades: [Double]

    func sceneGeometry() -> SCNGeometry {
        guard visualVertices.count >= 4,
              visualVertices.count % 2 == 0 else {
            return SCNGeometry()
        }

        let pointCount = visualVertices.count / 2
        guard visualSegmentGrades.count == pointCount - 1 else {
            return SCNGeometry()
        }

        let positions = visualVertices.map {
            SCNVector3($0.x, $0.y, $0.z)
        }

        var normals = Array(
            repeating: SCNVector3Zero,
            count: positions.count
        )

        for segment in visualSegmentGrades.indices {
            let l0 = segment * 2
            let r0 = l0 + 1
            let l1 = (segment + 1) * 2
            let r1 = l1 + 1

            let a = positions[l0]
            let b = positions[r0]
            let c = positions[l1]

            let ab = SCNVector3(b.x-a.x, b.y-a.y, b.z-a.z)
            let ac = SCNVector3(c.x-a.x, c.y-a.y, c.z-a.z)

            var n = normalize(cross(ac, ab))
            if n.y < 0 {
                n = SCNVector3(-n.x, -n.y, -n.z)
            }

            normals[l0] = add(normals[l0], n)
            normals[r0] = add(normals[r0], n)
            normals[l1] = add(normals[l1], n)
            normals[r1] = add(normals[r1], n)
        }

        normals = normals.map(normalize)

        let vertexSource = SCNGeometrySource(vertices: positions)
        let normalSource = SCNGeometrySource(normals: normals)

        var bucketIndices: [Int: [Int32]] = [:]

        for segment in visualSegmentGrades.indices {
            let bucket = gradeBucket(visualSegmentGrades[segment])

            let l0 = Int32(segment * 2)
            let r0 = l0 + 1
            let l1 = Int32((segment + 1) * 2)
            let r1 = l1 + 1

            bucketIndices[bucket, default: []].append(
                contentsOf: [
                    l0, l1, r0,
                    r0, l1, r1
                ]
            )
        }

        let sortedBuckets = bucketIndices.keys.sorted()
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []

        for bucket in sortedBuckets {
            guard let indices = bucketIndices[bucket],
                  !indices.isEmpty else { continue }

            let data = indices.withUnsafeBytes { Data($0) }

            elements.append(
                SCNGeometryElement(
                    data: data,
                    primitiveType: .triangles,
                    primitiveCount: indices.count / 3,
                    bytesPerIndex: MemoryLayout<Int32>.size
                )
            )

            materials.append(material(forBucket: bucket))
        }

        let geometry = SCNGeometry(
            sources: [vertexSource, normalSource],
            elements: elements
        )
        geometry.materials = materials
        return geometry
    }

    private func gradeBucket(_ grade: Double) -> Int {
        switch grade {
        case ..<0: return 0
        case 0..<3: return 1
        case 3..<5: return 2
        case 5..<7: return 3
        case 7..<9: return 4
        case 9..<12: return 5
        case 12..<15: return 6
        default: return 7
        }
    }

    private func material(forBucket bucket: Int) -> SCNMaterial {
        let color: UIColor
        switch bucket {
        case 0:
            color = UIColor(red: 0.16, green: 0.58, blue: 0.92, alpha: 1)
        case 1:
            color = UIColor(red: 0.24, green: 0.76, blue: 0.48, alpha: 1)
        case 2:
            color = UIColor(red: 0.93, green: 0.78, blue: 0.20, alpha: 1)
        case 3:
            color = UIColor(red: 0.98, green: 0.53, blue: 0.12, alpha: 1)
        case 4:
            color = UIColor(red: 0.95, green: 0.32, blue: 0.10, alpha: 1)
        case 5:
            color = UIColor(red: 0.88, green: 0.12, blue: 0.12, alpha: 1)
        case 6:
            color = UIColor(red: 0.72, green: 0.08, blue: 0.22, alpha: 1)
        default:
            color = UIColor(red: 0.50, green: 0.07, blue: 0.32, alpha: 1)
        }

        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.035)
        material.roughness.contents = 0.90
        material.metalness.contents = 0.0
        material.lightingModel = .physicallyBased
        material.isDoubleSided = true
        return material
    }

    private func cross(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3(
            a.y*b.z - a.z*b.y,
            a.z*b.x - a.x*b.z,
            a.x*b.y - a.y*b.x
        )
    }

    private func add(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3(a.x+b.x, a.y+b.y, a.z+b.z)
    }

    private func normalize(_ v: SCNVector3) -> SCNVector3 {
        let l = sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
        guard l > 0.000001 else { return SCNVector3(0,1,0) }
        return SCNVector3(v.x/l, v.y/l, v.z/l)
    }
}
