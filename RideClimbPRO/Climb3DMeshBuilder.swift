import Foundation

struct Climb3DMeshBuilder {
    let stlHalfWidthM: Double = 5.0
    let visualHalfWidthM: Double = 3.0
    let stlJoinLimitMultiplier: Double = 2.0
    let visualJoinLimitMultiplier: Double = 1.30

    let verticalExaggeration: Double = 5.0
    let baseHeightM: Double = 8.0
    let centerlineLiftM: Double = 0.10

    // Build 29: visual-only elevation filtering. The RideModel route and all
    // trainer/virtual-shift calculations remain exactly the validated Build 25
    // path. Only the rendered Z profile is filtered.
    let visualElevationSmoothRadiusM: Double = 28.0

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
        let visualElevations = smoothedVisualElevations(
            route.points,
            radiusM: visualElevationSmoothRadiusM
        )
        let minElevation = visualElevations.min() ?? 0

        // X/Z (map geometry) are never smoothed. This is critical on tight
        // hairpins: the road follows the actual GPX polyline instead of cutting
        // across neighbouring legs. Only elevation is filtered for rendering.
        let allPoints: [ProjectedPoint] = route.points.enumerated().map { index, point in
            ProjectedPoint(
                distanceM: point.distanceM,
                x: (point.longitude - first.longitude) * lonScale,
                y: (visualElevations[index] - minElevation) * verticalExaggeration,
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

    /// Preserve the GPX plan-view geometry. Earlier builds attempted to remove
    /// "reversals" and could delete a genuine point at a hairpin, producing a
    /// chord through the bend. Build 29 removes only true/near duplicates.
    private func prepareMeshPath(_ source: [ProjectedPoint]) -> [ProjectedPoint] {
        guard source.count >= 2 else { return source }

        let minimumDistanceM = 0.25
        var filtered: [ProjectedPoint] = []
        filtered.reserveCapacity(source.count)
        filtered.append(source[0])

        for point in source.dropFirst() {
            guard let last = filtered.last else {
                filtered.append(point)
                continue
            }

            if horizontalDistance(last, point) >= minimumDistanceM {
                filtered.append(point)
            }
        }

        // Always retain the true GPX endpoint even when it is very close to the
        // previous sample.
        if let sourceLast = source.last,
           let filteredLast = filtered.last,
           sourceLast.distanceM > filteredLast.distanceM,
           horizontalDistance(filteredLast, sourceLast) > 0.01 {
            filtered.append(sourceLast)
        }

        return filtered.count >= 2 ? filtered : source
    }

    /// Triangular, distance-domain smoothing used only for 3D elevation.
    /// Latitude/longitude and RideModel's elevations are intentionally untouched.
    private func smoothedVisualElevations(
        _ points: [RoutePoint],
        radiusM: Double
    ) -> [Double] {
        guard points.count >= 3, radiusM > 0 else {
            return points.map(\.elevationM)
        }

        var result = Array(repeating: 0.0, count: points.count)
        var left = 0
        var right = 0

        for i in points.indices {
            let center = points[i].distanceM

            while left < i && center - points[left].distanceM > radiusM {
                left += 1
            }

            if right < i { right = i }
            while right + 1 < points.count &&
                    points[right + 1].distanceM - center <= radiusM {
                right += 1
            }

            var weighted = 0.0
            var weightSum = 0.0

            if left <= right {
                for j in left...right {
                    let delta = abs(points[j].distanceM - center)
                    let weight = max(0.001, 1.0 - delta / radiusM)
                    weighted += points[j].elevationM * weight
                    weightSum += weight
                }
            }

            result[i] = weightSum > 0 ? weighted / weightSum : points[i].elevationM
        }

        return result
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
