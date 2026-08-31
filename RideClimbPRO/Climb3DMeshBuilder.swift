import Foundation

struct Climb3DMeshBuilder {
    let stlHalfWidthM: Double = 5.0
    let visualHalfWidthM: Double = 3.0
    let stlJoinLimitMultiplier: Double = 2.0
    let visualJoinLimitMultiplier: Double = 1.30

    let verticalExaggeration: Double = 5.0
    let baseHeightM: Double = 8.0
    let centerlineLiftM: Double = 0.10

    private struct ProjectedPoint {
        let distanceM: Double
        let x: Double
        let y: Double
        let z: Double
    }

    func build(from route: GPXRoute) throws -> Climb3DMesh {
        guard route.points.count >= 2 else {
            throw NSError(
                domain: "RideClimbPRO3D.Mesh",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Route too short"]
            )
        }

        let first = route.points[0]
        let latScale = 111_320.0
        let lonScale = 111_320.0 * cos(first.latitude * .pi / 180)
        let minElevation = route.points.map(\.elevationM).min() ?? 0

        let allPoints: [ProjectedPoint] = route.points.map { point in
            ProjectedPoint(
                distanceM: point.distanceM,
                x: (point.longitude - first.longitude) * lonScale,
                y: (point.elevationM - minElevation) * verticalExaggeration,
                z: -(point.latitude - first.latitude) * latScale
            )
        }

        let meshPoints = prepareMeshPath(allPoints)
        guard meshPoints.count >= 2 else {
            throw NSError(
                domain: "RideClimbPRO3D.Mesh",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create 3D path"]
            )
        }

        // Closed solid for STL.
        let stlEdges = buildBufferedEdges(
            meshPoints,
            halfWidth: stlHalfWidthM,
            joinLimitMultiplier: stlJoinLimitMultiplier
        )

        let baseY = -baseHeightM
        var vertices: [Climb3DVertex] = []
        vertices.reserveCapacity(meshPoints.count * 4)

        for i in meshPoints.indices {
            let p = meshPoints[i]
            let e = stlEdges[i]
            vertices.append(Climb3DVertex(x: Float(e.left.x),  y: Float(p.y),    z: Float(e.left.z)))
            vertices.append(Climb3DVertex(x: Float(e.right.x), y: Float(p.y),    z: Float(e.right.z)))
            vertices.append(Climb3DVertex(x: Float(e.left.x),  y: Float(baseY), z: Float(e.left.z)))
            vertices.append(Climb3DVertex(x: Float(e.right.x), y: Float(baseY), z: Float(e.right.z)))
        }

        var triangles: [Climb3DTriangle] = []
        func idx(_ i: Int, _ o: Int) -> Int32 { Int32(i * 4 + o) }

        for i in 0..<(meshPoints.count - 1) {
            triangles += [
                Climb3DTriangle(a: idx(i,0), b: idx(i,1), c: idx(i+1,0)),
                Climb3DTriangle(a: idx(i,1), b: idx(i+1,1), c: idx(i+1,0)),
                Climb3DTriangle(a: idx(i,2), b: idx(i,0), c: idx(i+1,2)),
                Climb3DTriangle(a: idx(i,0), b: idx(i+1,0), c: idx(i+1,2)),
                Climb3DTriangle(a: idx(i,1), b: idx(i,3), c: idx(i+1,1)),
                Climb3DTriangle(a: idx(i,3), b: idx(i+1,3), c: idx(i+1,1)),
                Climb3DTriangle(a: idx(i,2), b: idx(i+1,2), c: idx(i,3)),
                Climb3DTriangle(a: idx(i,3), b: idx(i+1,2), c: idx(i+1,3))
            ]
        }

        triangles += [
            Climb3DTriangle(a: idx(0,2), b: idx(0,1), c: idx(0,0)),
            Climb3DTriangle(a: idx(0,2), b: idx(0,3), c: idx(0,1))
        ]

        let last = meshPoints.count - 1
        triangles += [
            Climb3DTriangle(a: idx(last,0), b: idx(last,1), c: idx(last,2)),
            Climb3DTriangle(a: idx(last,1), b: idx(last,3), c: idx(last,2))
        ]

        // Continuous visual ribbon.
        let visualEdges = buildBufferedEdges(
            meshPoints,
            halfWidth: visualHalfWidthM,
            joinLimitMultiplier: visualJoinLimitMultiplier
        )

        var visualVertices: [Climb3DVertex] = []
        visualVertices.reserveCapacity(meshPoints.count * 2)

        for i in meshPoints.indices {
            let p = meshPoints[i]
            let e = visualEdges[i]
            visualVertices.append(
                Climb3DVertex(x: Float(e.left.x), y: Float(p.y), z: Float(e.left.z))
            )
            visualVertices.append(
                Climb3DVertex(x: Float(e.right.x), y: Float(p.y), z: Float(e.right.z))
            )
        }

        // IMPORTANT: no point-to-point derivative here.
        // The 3D road uses the exact RideClimbPRO terrain algorithm.
        let visualSegmentGrades: [Double] =
            (0..<(meshPoints.count - 1)).map { i in
                route.terrainGrade(at: meshPoints[i].distanceM)
            }

        // Full route centerline preserves a 1:1 mapping with RideModel.distanceM.
        let centerline = allPoints.map {
            Climb3DVertex(
                x: Float($0.x),
                y: Float($0.y + centerlineLiftM),
                z: Float($0.z)
            )
        }

        return Climb3DMesh(
            vertices: vertices,
            triangles: triangles,
            centerline: centerline,
            visualVertices: visualVertices,
            visualSegmentGrades: visualSegmentGrades
        )
    }

    private func prepareMeshPath(_ source: [ProjectedPoint]) -> [ProjectedPoint] {
        guard source.count >= 2 else { return source }

        let minimumDistanceM = 1.5
        var filtered: [ProjectedPoint] = [source[0]]

        for point in source.dropFirst().dropLast() {
            if let last = filtered.last,
               horizontalDistance(last, point) >= minimumDistanceM {
                filtered.append(point)
            }
        }

        if let last = source.last {
            if filtered.count == 1 ||
                horizontalDistance(filtered[filtered.count - 1], last) > 0.01 {
                filtered.append(last)
            }
        }

        guard filtered.count >= 4 else { return filtered }

        var result: [ProjectedPoint] = []
        var i = 0

        while i < filtered.count {
            if i > 0 && i < filtered.count - 2 {
                let a0 = segmentAngle(filtered[i-1], filtered[i])
                let a1 = segmentAngle(filtered[i], filtered[i+1])
                let a2 = segmentAngle(filtered[i+1], filtered[i+2])

                let t1 = normalizedAngle(a1 - a0)
                let t2 = normalizedAngle(a2 - a1)

                if abs(t1) > .pi / 2 && abs(t2) > .pi / 2 {
                    i += 1
                    continue
                }
            }

            result.append(filtered[i])
            i += 1
        }

        return result.count >= 2 ? result : filtered
    }

    private func buildBufferedEdges(
        _ points: [ProjectedPoint],
        halfWidth: Double,
        joinLimitMultiplier: Double
    ) -> [(left: (x: Double, z: Double), right: (x: Double, z: Double))] {
        guard points.count >= 2 else { return [] }

        var result: [(left: (x: Double, z: Double), right: (x: Double, z: Double))] = []
        result.reserveCapacity(points.count)

        for i in points.indices {
            let incoming: Double
            let outgoing: Double

            if i == 0 {
                incoming = segmentAngle(points[0], points[1])
                outgoing = incoming
            } else if i == points.count - 1 {
                incoming = segmentAngle(points[i-1], points[i])
                outgoing = incoming
            } else {
                incoming = segmentAngle(points[i-1], points[i])
                outgoing = segmentAngle(points[i], points[i+1])
            }

            let relative = normalizedAngle(outgoing - incoming)
            let joint = incoming + relative / 2
            let cosHalf = cos(relative / 2)

            var radius = halfWidth
            if abs(cosHalf) > 0.0001 {
                radius = halfWidth / cosHalf
            }

            let limit = halfWidth * joinLimitMultiplier
            radius = min(limit, max(-limit, radius))

            let p = points[i]
            let leftAngle = joint + .pi / 2
            let rightAngle = joint - .pi / 2

            result.append(
                (
                    left: (
                        x: p.x + radius * cos(leftAngle),
                        z: p.z + radius * sin(leftAngle)
                    ),
                    right: (
                        x: p.x + radius * cos(rightAngle),
                        z: p.z + radius * sin(rightAngle)
                    )
                )
            )
        }

        return result
    }

    private func segmentAngle(_ a: ProjectedPoint, _ b: ProjectedPoint) -> Double {
        atan2(b.z - a.z, b.x - a.x)
    }

    private func normalizedAngle(_ angle: Double) -> Double {
        var a = angle
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }

    private func horizontalDistance(_ a: ProjectedPoint, _ b: ProjectedPoint) -> Double {
        let dx = b.x - a.x
        let dz = b.z - a.z
        return sqrt(dx*dx + dz*dz)
    }
}
